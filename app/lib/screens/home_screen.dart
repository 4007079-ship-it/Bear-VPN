import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

import '../import_flow.dart';
import '../nodes_store.dart';
import '../vpn_controller.dart';
import '../widgets/exit_ip.dart';
import '../widgets/logo.dart';
import '../widgets/mode_selector.dart';
import '../widgets/node_info.dart';
import '../widgets/traffic_card.dart';

/// Главная: выбор сервера, большая кнопка подключения, статус и трафик.
class HomeScreen extends StatelessWidget {
  final NodesStore store;
  final VpnController vpn;

  /// На широком экране трафик показывается в боковой панели.
  final bool showTraffic;

  const HomeScreen({
    super.key,
    required this.store,
    required this.vpn,
    this.showTraffic = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, vpn]),
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final nodes = store.nodes;
        final selected = nodes
            .where((n) => n.id == store.selectedId)
            .cast<ProxyNode?>()
            .firstWhere((_) => true, orElse: () => null);
        final unsupported =
            selected == null ? null : VpnController.unsupportedReason(selected);
        final locked = vpn.state != VpnState.disconnected;

        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                children: [
                  // Заголовок
                  Row(children: [
                    const AppLogo(size: 30),
                    const SizedBox(width: 10),
                    const Flexible(
                      child: Text(appName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w600)),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Добавить сервер',
                      icon: Icon(Icons.add, color: cs.primary),
                      onPressed: () => ImportFlow.show(context, store),
                    ),
                  ]),
                  const SizedBox(height: 16),

                  // Выбор сервера
                  if (nodes.isEmpty)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: () => ImportFlow.show(context, store),
                      icon: const Icon(Icons.add),
                      label: const Text('Добавить сервер'),
                    )
                  else
                    DropdownButtonFormField<String>(
                      value: selected?.id,
                      isExpanded: true,
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                      ),
                      items: [
                        for (final n in nodes)
                          DropdownMenuItem(
                            value: n.id,
                            child: Row(children: [
                              ProtocolChip(n.protocol),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(n.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                              ),
                            ]),
                          ),
                      ],
                      onChanged: locked
                          ? null
                          : (id) {
                              if (id != null) store.select(id);
                            },
                    ),

                  // Кнопка
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ConnectButton(
                            state: vpn.state,
                            enabled: vpn.state == VpnState.connecting ||
                                vpn.state == VpnState.connected ||
                                (selected != null && unsupported == null),
                            onTap: () {
                              switch (vpn.state) {
                                case VpnState.connected:
                                case VpnState.connecting:
                                  vpn.disconnect();
                                case VpnState.disconnected:
                                  if (selected != null) vpn.connect(selected);
                                case VpnState.disconnecting:
                                  break;
                              }
                            },
                          ),
                          const SizedBox(height: 24),
                          Text(
                            switch (vpn.state) {
                              VpnState.disconnected => selected == null
                                  ? 'Добавьте сервер'
                                  : 'Нажмите для подключения',
                              VpnState.connecting =>
                                'Подключение… (нажмите для отмены)',
                              VpnState.connected =>
                                'Подключено · ${formatDuration(vpn.duration)}',
                              VpnState.disconnecting => 'Отключение…',
                            },
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w500),
                          ),
                          if (vpn.state == VpnState.connected) ...[
                            const SizedBox(height: 6),
                            TextButton.icon(
                              onPressed: vpn.measureDelay,
                              icon: const Icon(Icons.network_ping, size: 18),
                              label: Text(vpn.delayMs == null
                                  ? 'Проверить пинг'
                                  : vpn.delayMs! < 0
                                      ? 'Пинг: ошибка'
                                      : 'Пинг ${vpn.delayMs} мс'),
                            ),
                            ExitIpCard(
                              vpn: vpn,
                              serverAddress: store.nodes
                                  .where((n) => n.id == vpn.activeNodeId)
                                  .firstOrNull
                                  ?.address,
                            ),
                          ],
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: ModeSelector(vpn: vpn),
                          ),
                          for (final (msg, isError) in [
                            if (unsupported != null &&
                                vpn.state == VpnState.disconnected)
                              (unsupported, true),
                            if (vpn.info != null) (vpn.info!, false),
                            if (vpn.error != null) (vpn.error!, true),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 460),
                                child: SelectableText(
                                  msg,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: isError ? cs.error : null),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),

                  if (showTraffic) TrafficRow(vpn: vpn),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Большая круглая кнопка подключения.
class ConnectButton extends StatefulWidget {
  final VpnState state;
  final bool enabled;
  final VoidCallback onTap;
  const ConnectButton(
      {super.key,
      required this.state,
      required this.enabled,
      required this.onTap});

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didUpdateWidget(covariant ConnectButton old) {
    super.didUpdateWidget(old);
    _syncAnimation();
  }

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  void _syncAnimation() {
    final busy = widget.state == VpnState.connecting ||
        widget.state == VpnState.disconnecting;
    if (busy && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!busy && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final connected = widget.state == VpnState.connected;
    final busy = widget.state == VpnState.connecting ||
        widget.state == VpnState.disconnecting;
    final fill = connected ? cs.primary : cs.surfaceContainerHigh;
    final iconColor = connected
        ? Colors.black
        : (widget.enabled || busy ? cs.primary : cs.outline);
    const size = 180.0;

    return Semantics(
      button: true,
      label: connected ? 'Отключить' : 'Подключить',
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: SizedBox(
            width: size + 24,
            height: size + 24,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (busy)
                  AnimatedBuilder(
                    animation: _spin,
                    builder: (_, __) => Transform.rotate(
                      angle: _spin.value * 2 * math.pi,
                      child: SizedBox(
                        width: size + 20,
                        height: size + 20,
                        child: CircularProgressIndicator(
                          value: 0.25,
                          strokeWidth: 4,
                          color: cs.primary,
                        ),
                      ),
                    ),
                  ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fill,
                    border: Border.all(
                        color: cs.primary.withValues(alpha: connected ? 1 : 0.6),
                        width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: cs.primary
                            .withValues(alpha: connected ? 0.45 : 0.2),
                        blurRadius: 40,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Icon(Icons.power_settings_new,
                      size: 84, color: iconColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
