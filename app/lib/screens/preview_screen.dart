import 'package:flutter/material.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

import '../nodes_store.dart';
import '../widgets/node_info.dart';

/// Предпросмотр импорта: карточки узлов с предупреждениями, чекбоксы
/// при множественном импорте, ошибки разбора отдельных элементов.
class PreviewScreen extends StatefulWidget {
  final NodesStore store;
  final ParseResult result;
  const PreviewScreen({super.key, required this.store, required this.result});

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  late final Map<String, List<ValidationIssue>> _issues;
  late final Set<String> _duplicates;
  late final Set<String> _checked;

  @override
  void initState() {
    super.initState();
    final nodes = widget.result.nodes;
    _issues = {for (final n in nodes) n.id: validateNode(n)};
    _duplicates = widget.store.duplicatesOf(nodes);
    _checked = {
      for (final n in nodes)
        if (_canAdd(n) && !_duplicates.contains(n.id)) n.id
    };
  }

  bool _canAdd(ProxyNode n) => !_issues[n.id]!.any((i) => i.isError);

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final multi = r.nodes.length > 1;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(multi ? 'Найдено узлов: ${r.nodes.length}' : 'Предпросмотр'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text('Формат: ${_formatLabel(r.format)}',
                style: TextStyle(color: cs.onSurfaceVariant)),
          ),
          if (r.issues.isNotEmpty)
            Card(
              color: cs.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Пропущено: ${r.issues.length}',
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: cs.onErrorContainer)),
                    for (final i in r.issues.take(10))
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                            '${i.index != null ? '#${i.index! + 1}: ' : ''}'
                            '${i.message}',
                            style: TextStyle(color: cs.onErrorContainer)),
                      ),
                    if (r.issues.length > 10)
                      Text('… и ещё ${r.issues.length - 10}',
                          style: TextStyle(color: cs.onErrorContainer)),
                  ],
                ),
              ),
            ),
          for (final n in r.nodes) _card(n, multi),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, 0),
                  child: const Text('Отмена'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _checked.isEmpty ? null : _add,
                  child: Text(multi
                      ? 'Добавить (${_checked.length})'
                      : 'Добавить'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(ProxyNode n, bool multi) {
    final issues = _issues[n.id]!;
    final canAdd = _canAdd(n);
    final dup = _duplicates.contains(n.id);
    final s = n.security;
    final rows = <(String, String)>[
      ('Адрес', n.address),
      if (!n.protocol.isWireGuardFamily) ...[
        ('Транспорт', n.transport.type),
        if (s.type != 'none') ('Шифрование', s.type),
        if (s.sni != null) ('SNI', s.sni!),
        if (n.flow != null) ('Flow', n.flow!),
        if (n.method != null) ('Шифр', n.method!),
        if (n.portRange != null) ('Порты', n.portRange!),
      ] else ...[
        if (n.wireguard!.addresses.isNotEmpty)
          ('Адрес в туннеле', n.wireguard!.addresses.join(', ')),
        if (n.wireguard!.dns.isNotEmpty) ('DNS', n.wireguard!.dns.join(', ')),
        if (n.wireguard!.awg != null)
          ('AmneziaWG', 'версия ${n.wireguard!.awg!.version}'),
      ],
    ];

    return Card(
      child: InkWell(
        onTap: canAdd && multi ? () => _toggle(n.id) : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (multi)
                    Checkbox(
                      value: _checked.contains(n.id),
                      onChanged: canAdd ? (_) => _toggle(n.id) : null,
                    ),
                  ProtocolChip(n.protocol),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(n.name,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final (k, v) in rows)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                          width: 130,
                          child: Text(k,
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant))),
                      Expanded(child: SelectableText(v)),
                    ],
                  ),
                ),
              if (dup)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('Уже добавлен',
                      style: TextStyle(fontStyle: FontStyle.italic)),
                ),
              for (final i in issues) IssueLine(i),
            ],
          ),
        ),
      ),
    );
  }

  void _toggle(String id) => setState(() {
        if (!_checked.remove(id)) _checked.add(id);
      });

  void _add() {
    final nodes =
        widget.result.nodes.where((n) => _checked.contains(n.id)).toList();
    widget.store.addAll(nodes);
    Navigator.pop(context, nodes.length);
  }

  static String _formatLabel(InputFormat f) => switch (f) {
        InputFormat.uri => 'ссылка',
        InputFormat.uriList => 'список ссылок',
        InputFormat.base64Subscription => 'base64-подписка',
        InputFormat.singBoxJson => 'sing-box JSON',
        InputFormat.xrayJson => 'Xray JSON',
        InputFormat.clashYaml => 'Clash YAML',
        InputFormat.amneziaKey => 'ключ AmneziaVPN',
        InputFormat.wireguardConf => 'конфиг WireGuard / AmneziaWG',
        InputFormat.subscriptionUrl => 'URL подписки',
        InputFormat.empty || InputFormat.unknown => 'не распознан',
      };
}
