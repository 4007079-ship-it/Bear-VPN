import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../vpn_controller.dart';

/// Переключатель режима подключения (как в Hiddify) и подсказки к нему.
class ModeSelector extends StatelessWidget {
  final VpnController vpn;
  const ModeSelector({super.key, required this.vpn});

  static String hint(ConnectionMode m) => switch (m) {
        ConnectionMode.proxy => 'Только локальный порт. Программы и браузер '
            'нужно направить на него вручную.',
        ConnectionMode.systemProxy => 'Браузеры и большинство программ '
            'идут через сервер. Игры и часть программ — напрямую.',
        ConnectionMode.vpn => Platform.isWindows
            ? 'Экспериментально. Весь трафик компьютера. Нужны права '
                'администратора.'
            : 'Весь трафик телефона идёт через сервер.',
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final locked = vpn.state != VpnState.disconnected;
    final modes = ConnectionMode.available;
    final showPorts = vpn.state == VpnState.connected &&
        (vpn.mode == ConnectionMode.proxy || VpnController.proxyOnlyMode) &&
        (vpn.httpPort != null || vpn.socksPort != null);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedButton<ConnectionMode>(
          showSelectedIcon: false,
          segments: [
            for (final m in modes)
              ButtonSegment(
                value: m,
                label: Text(m.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ],
          selected: {vpn.mode},
          onSelectionChanged: locked ? null : (s) => vpn.setMode(s.first),
        ),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            locked ? '${hint(vpn.mode)}\nРежим меняется после отключения.' : hint(vpn.mode),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
        if (vpn.state == VpnState.connected && vpn.activeServers > 1)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Серверов в работе: ${vpn.activeServers}',
                style: TextStyle(fontSize: 12, color: cs.primary)),
          ),
        if (showPorts)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (vpn.httpPort != null)
                  _PortChip(label: 'HTTP', port: vpn.httpPort!),
                if (vpn.socksPort != null)
                  _PortChip(label: 'SOCKS5', port: vpn.socksPort!),
              ],
            ),
          ),
        if (Platform.isWindows &&
            vpn.mode == ConnectionMode.vpn &&
            !locked)
          FutureBuilder<bool>(
            future: VpnController.isWindowsAdmin(),
            builder: (context, snap) {
              if (snap.data != false) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.admin_panel_settings_outlined),
                  label: const Text('Перезапустить от имени администратора'),
                  onPressed: vpn.relaunchAsAdmin,
                ),
              );
            },
          ),
      ],
    );
  }
}

class _PortChip extends StatelessWidget {
  final String label;
  final int port;
  const _PortChip({required this.label, required this.port});

  @override
  Widget build(BuildContext context) {
    final addr = '127.0.0.1:$port';
    return ActionChip(
      avatar: const Icon(Icons.copy, size: 16),
      label: Text('$label $addr'),
      onPressed: () {
        Clipboard.setData(ClipboardData(text: addr));
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Скопировано: $addr')));
      },
    );
  }
}
