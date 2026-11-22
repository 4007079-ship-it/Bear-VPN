import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../vpn_controller.dart';

/// Вкладка «Логи»: диагностика ядра и плагина (без ключей).
class LogsScreen extends StatefulWidget {
  final VpnController vpn;
  const LogsScreen({super.key, required this.vpn});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  String? _text;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final t = await widget.vpn.diagnostics();
    if (!mounted) return;
    setState(() {
      _text = t;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Логи'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
          IconButton(
            tooltip: 'Копировать',
            icon: const Icon(Icons.copy),
            onPressed: _text == null
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: _text!));
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Скопировано')));
                  },
          ),
        ],
      ),
      body: _text == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SelectableText(
                  _text!,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            ),
    );
  }
}
