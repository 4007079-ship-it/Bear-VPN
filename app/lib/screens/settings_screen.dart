import 'dart:io';

import 'package:flutter/material.dart';

import '../core_tweaks.dart';
import '../vpn_controller.dart';

/// Включаемые настройки. Всё выключено по умолчанию — Bear VPN работает как
/// обычно; включать по одной, если начались проблемы с блокировками.
class SettingsScreen extends StatelessWidget {
  final VpnController vpn;
  const SettingsScreen({super.key, required this.vpn});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: vpn,
      builder: (context, _) {
        final s = vpn.settings;
        final cs = Theme.of(context).colorScheme;
        final connected = vpn.state != VpnState.disconnected;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Настройки'),
            actions: [
              TextButton(
                onPressed: s.anyEnabled ? () => _reset(context) : null,
                child: const Text('Сбросить'),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              if (connected)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Изменения применятся при следующем подключении. '
                    'Отключитесь и подключитесь снова.',
                    style: TextStyle(color: cs.onSecondaryContainer),
                  ),
                ),
              const _Header('Обход блокировок'),
              SwitchListTile(
                title: const Text('Резать первый пакет (fragment)'),
                subtitle: const Text(
                    'Начало соединения уходит кусками — провайдеру сложнее '
                    'понять, куда вы подключаетесь. Для TCP-серверов; '
                    'Hysteria2 не затрагивает.'),
                value: s.fragment,
                onChanged: (v) => vpn.updateSettings((s) => s.fragment = v),
              ),
              if (s.fragment) ...[
                _RangeField(
                  label: 'Размер куска, байт',
                  value: s.fragmentLength,
                  onChanged: (v) =>
                      vpn.updateSettings((s) => s.fragmentLength = v),
                ),
                _RangeField(
                  label: 'Пауза между кусками, мс',
                  value: s.fragmentInterval,
                  onChanged: (v) =>
                      vpn.updateSettings((s) => s.fragmentInterval = v),
                ),
              ],
              SwitchListTile(
                title: const Text('Несколько соединений XHTTP (xmux)'),
                subtitle: const Text(
                    'Трафик делится на несколько параллельных соединений к '
                    'серверу — ни одно не доходит до порога, после которого '
                    'провайдер «замораживает» связь. Только для серверов XHTTP.'),
                value: s.xmux,
                onChanged: (v) => vpn.updateSettings((s) => s.xmux = v),
              ),
              if (s.xmux)
                _Stepper(
                  label: 'Соединений',
                  value: s.xmuxConnections,
                  min: 2,
                  max: 16,
                  onChanged: (v) =>
                      vpn.updateSettings((s) => s.xmuxConnections = v),
                ),
              const _Header('Серверы'),
              SwitchListTile(
                title: const Text('Несколько серверов сразу'),
                subtitle: Text(vpn.multiServerAvailable
                    ? 'Работают все серверы той же подписки (или списка '
                        '«Мои серверы»). Если один перестал отвечать, трафик '
                        'сам уходит на другие.'
                    : 'В режиме VPN на Windows пока недоступно — '
                        'используйте «Системный прокси».'),
                value: s.multiServer,
                onChanged: (v) => vpn.updateSettings((s) => s.multiServer = v),
              ),
              if (s.multiServer) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: SegmentedButton<BalanceStrategy>(
                    showSelectedIcon: false,
                    segments: [
                      for (final b in BalanceStrategy.values)
                        ButtonSegment(value: b, label: Text(b.label)),
                    ],
                    selected: {s.strategy},
                    onSelectionChanged: (v) =>
                        vpn.updateSettings((s) => s.strategy = v.first),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    s.strategy == BalanceStrategy.fastest
                        ? 'Всё идёт через самый быстрый сервер, остальные '
                            'в запасе.'
                        : 'Соединения раскладываются по всем живым серверам. '
                            'Сайты, которые следят за IP (банки), могут '
                            'попросить войти заново.',
                    style:
                        TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
                _Stepper(
                  label: 'Не больше серверов',
                  value: s.maxServers,
                  min: 2,
                  max: 20,
                  onChanged: (v) =>
                      vpn.updateSettings((s) => s.maxServers = v),
                ),
              ],
              if (Platform.isWindows) ...[
                const _Header('Прочее'),
                SwitchListTile(
                  title: const Text('Статистика трафика'),
                  subtitle: const Text(
                      'Скорость и объём на Windows. Выключите, если '
                      'с ней не подключается.'),
                  value: vpn.windowsStats,
                  onChanged: vpn.setWindowsStats,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _reset(BuildContext context) {
    vpn.updateSettings((s) {
      final d = CoreSettings();
      s
        ..fragment = d.fragment
        ..fragmentLength = d.fragmentLength
        ..fragmentInterval = d.fragmentInterval
        ..xmux = d.xmux
        ..xmuxConnections = d.xmuxConnections
        ..multiServer = d.multiServer
        ..strategy = d.strategy
        ..maxServers = d.maxServers;
    });
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Настройки сброшены')));
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary)),
      );
}

class _RangeField extends StatefulWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  const _RangeField(
      {required this.label, required this.value, required this.onChanged});

  @override
  State<_RangeField> createState() => _RangeFieldState();
}

class _RangeFieldState extends State<_RangeField> {
  late final _c = TextEditingController(text: widget.value);
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(32, 4, 16, 8),
        child: TextField(
          controller: _c,
          keyboardType: TextInputType.text,
          decoration: InputDecoration(
            labelText: widget.label,
            helperText: 'Число или диапазон, например 100-200',
            errorText: _error,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (v) {
            final ok = CoreSettings.isValidRange(v);
            setState(() => _error = ok ? null : 'Например: 100-200');
            if (ok) widget.onChanged(v.trim());
          },
        ),
      );
}

class _Stepper extends StatelessWidget {
  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  const _Stepper(
      {required this.label,
      required this.value,
      required this.min,
      required this.max,
      required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 8, 0),
        child: Row(children: [
          Expanded(child: Text(label)),
          IconButton(
            icon: const Icon(Icons.remove),
            onPressed: value > min ? () => onChanged(value - 1) : null,
          ),
          SizedBox(
              width: 32,
              child: Text('$value',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: value < max ? () => onChanged(value + 1) : null,
          ),
        ]),
      );
}
