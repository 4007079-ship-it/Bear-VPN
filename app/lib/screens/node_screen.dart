import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

import '../nodes_store.dart';
import '../widgets/node_info.dart';

/// Карточка узла: параметры (секреты скрыты), предупреждения, «Поделиться / QR».
class NodeScreen extends StatefulWidget {
  final NodesStore store;
  final ProxyNode node;
  const NodeScreen({super.key, required this.store, required this.node});

  @override
  State<NodeScreen> createState() => _NodeScreenState();
}

class _NodeScreenState extends State<NodeScreen> {
  bool _showSecrets = false;

  String _secret(String? v) =>
      v == null ? '—' : (_showSecrets ? v : '•' * v.length.clamp(6, 12).toInt());

  @override
  Widget build(BuildContext context) {
    final n = widget.node;
    final issues = validateNode(n);
    final s = n.security;
    final wg = n.wireguard;
    final awg = wg?.awg;

    final rows = <(String, String)>[
      ('Протокол', protocolLabel(n.protocol)),
      ('Адрес', n.address),
      if (n.uuid != null) ('UUID', _secret(n.uuid)),
      if (n.password != null) ('Пароль', _secret(n.password)),
      if (n.username != null) ('Логин', n.username!),
      if (n.method != null) ('Шифр', n.method!),
      if (n.flow != null) ('Flow', n.flow!),
      if (n.portRange != null) ('Порты', n.portRange!),
      if (n.obfs != null) ('Obfs', n.obfs!),
      if (!n.protocol.isWireGuardFamily) ...[
        ('Транспорт', n.transport.type),
        if (n.transport.host != null) ('Host', n.transport.host!),
        if (n.transport.path != null) ('Path', n.transport.path!),
        if (n.transport.serviceName != null)
          ('gRPC service', n.transport.serviceName!),
        ('Шифрование', s.type),
        if (s.sni != null) ('SNI', s.sni!),
        if (s.fingerprint != null) ('Fingerprint', s.fingerprint!),
        if (s.publicKey != null) ('Public key', s.publicKey!),
        if (s.shortId != null) ('Short ID', _secret(s.shortId)),
        if (s.alpn.isNotEmpty) ('ALPN', s.alpn.join(', ')),
      ],
      if (wg != null) ...[
        ('Private key', _secret(wg.privateKey)),
        ('Public key сервера', wg.peerPublicKey),
        if (wg.presharedKey != null) ('Preshared key', _secret(wg.presharedKey)),
        ('Address', wg.addresses.join(', ')),
        if (wg.dns.isNotEmpty) ('DNS', wg.dns.join(', ')),
        if (wg.mtu != null) ('MTU', '${wg.mtu}'),
        ('AllowedIPs', wg.allowedIps.join(', ')),
        if (wg.persistentKeepalive != null)
          ('Keepalive', '${wg.persistentKeepalive}'),
      ],
      if (awg != null) ...[
        ('AWG версия', awg.version),
        for (final e in awg.toIniEntries()) (e.key, e.value),
      ],
      ('Источник', n.source.type.name),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: _showSecrets ? 'Скрыть ключи' : 'Показать ключи',
            icon: Icon(_showSecrets ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showSecrets = !_showSecrets),
          ),
          IconButton(
            tooltip: 'Удалить',
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              widget.store.remove(n.id);
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          if (issues.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [for (final i in issues) IssueLine(i)],
                ),
              ),
            ),
          for (final (k, v) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 150,
                    child: Text(k,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ),
                  Expanded(child: SelectableText(v)),
                ],
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => shareNode(context, n),
        icon: const Icon(Icons.qr_code_2),
        label: const Text('Поделиться / QR'),
      ),
    );
  }
}

/// «Поделиться»: QR-код и копирование ссылки (с предупреждением о ключах).
Future<void> shareNode(BuildContext context, ProxyNode n) async {
  if (containsSecrets(n)) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('QR содержит ключи доступа'),
        content: const Text(
            'Любой, кто увидит этот QR-код или текст, сможет подключиться '
            'к серверу. Показывайте его только тем, кому доверяете.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Показать')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
  }
  final text = shareUri(n);
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(
                data: text,
                version: QrVersions.auto,
                size: 300,
                backgroundColor: Colors.white,
                errorStateBuilder: (context, error) => const SizedBox(
                  height: 120,
                  child: Center(
                    child: Text(
                      'Данные слишком длинные для QR-кода. '
                      'Скопируйте текст.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text('${text.length} символов',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy),
          label: const Text('Копировать'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) Navigator.pop(context);
          },
        ),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть')),
      ],
    ),
  );
}
