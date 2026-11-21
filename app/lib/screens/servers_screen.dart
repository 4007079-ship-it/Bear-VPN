import 'package:flutter/material.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

import '../import_flow.dart';
import '../nodes_store.dart';
import '../subscription.dart';
import '../vpn_controller.dart';
import '../widgets/node_info.dart';
import 'node_screen.dart';

/// Вкладка «Серверы»: список узлов, выбор, добавление.
class ServersScreen extends StatelessWidget {
  final NodesStore store;
  final VpnController vpn;
  const ServersScreen({super.key, required this.store, required this.vpn});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, vpn]),
      builder: (context, _) {
        final nodes = store.nodes;
        final manual = [
          for (final n in nodes)
            if (store.subscriptionOf(n) == null) n
        ];
        return Scaffold(
          appBar: AppBar(
            title: const Text('Серверы'),
            actions: [
              IconButton(
                tooltip: 'Добавить',
                icon: const Icon(Icons.add),
                onPressed: () => ImportFlow.show(context, store),
              ),
            ],
          ),
          body: nodes.isEmpty
              ? EmptyServers(onAdd: () => ImportFlow.show(context, store))
              : ListView(
                  padding: const EdgeInsets.only(bottom: 96),
                  children: [
                    for (final sub in store.subscriptions) ...[
                      _SubscriptionHeader(store: store, sub: sub),
                      for (final n in store.nodesOf(sub))
                        _NodeTile(store: store, vpn: vpn, node: n),
                    ],
                    if (store.subscriptions.isNotEmpty &&
                        manual.isNotEmpty)
                      const _SectionTitle('Мои серверы'),
                    for (final n in manual)
                      _NodeTile(store: store, vpn: vpn, node: n),
                  ],
                ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => ImportFlow.show(context, store),
            icon: const Icon(Icons.add),
            label: const Text('Добавить'),
          ),
        );
      },
    );
  }
}

class _NodeTile extends StatelessWidget {
  final NodesStore store;
  final VpnController vpn;
  final ProxyNode node;
  const _NodeTile(
      {required this.store, required this.vpn, required this.node});

  @override
  Widget build(BuildContext context) {
    final n = node;
    final cs = Theme.of(context).colorScheme;
    final hasErrors = validateNode(n).any((issue) => issue.isError);
    final isActive =
        vpn.activeNodeId == n.id && vpn.state == VpnState.connected;
    return ListTile(
      selected: store.selectedId == n.id,
      leading: IconButton(
        tooltip: 'Выбрать',
        icon: Icon(store.selectedId == n.id
            ? Icons.radio_button_checked
            : Icons.radio_button_unchecked),
        onPressed: () => store.select(n.id),
      ),
      title: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(children: [
          ProtocolChip(n.protocol),
          const SizedBox(width: 8),
          Expanded(
            child: Text(nodeSubtitle(n),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ]),
      ),
      trailing: isActive
          ? Icon(Icons.bolt, color: cs.primary)
          : hasErrors
              ? Icon(Icons.error_outline, color: cs.error)
              : const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => NodeScreen(store: store, node: n))),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

/// Шапка подписки: название, трафик, срок, обновление и удаление.
class _SubscriptionHeader extends StatefulWidget {
  final NodesStore store;
  final Subscription sub;
  const _SubscriptionHeader({required this.store, required this.sub});

  @override
  State<_SubscriptionHeader> createState() => _SubscriptionHeaderState();
}

class _SubscriptionHeaderState extends State<_SubscriptionHeader> {
  bool _busy = false;

  Subscription get sub => widget.sub;

  static String _two(int v) => v.toString().padLeft(2, '0');
  static String _date(DateTime d) {
    final l = d.toLocal();
    return '${_two(l.day)}.${_two(l.month)}.${l.year}';
  }

  static String _ago(DateTime d) {
    final m = DateTime.now().difference(d).inMinutes;
    if (m < 1) return 'только что';
    if (m < 60) return '$m мин назад';
    if (m < 60 * 24) return '${m ~/ 60} ч назад';
    return _date(d);
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    final ok = await widget.store.refreshSubscription(sub);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'Обновлено: серверов — ${widget.store.nodesOf(sub).length}'
            : sub.lastError ?? 'Ошибка обновления')));
  }

  Future<void> _delete() async {
    final keep = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Удалить подписку «${sub.name}»?'),
        content: const Text('Серверы из подписки можно удалить вместе с ней '
            'или оставить как обычные (без обновления).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Оставить серверы')),
          FilledButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Удалить всё')),
        ],
      ),
    );
    if (keep == null) return;
    widget.store.removeSubscription(sub, keepNodes: keep);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final u = sub.usage;
    final lines = <String>[
      '${widget.store.nodesOf(sub).length} серв. · '
          '${sub.updatedAt == null ? 'не обновлялась' : 'обновлено ${_ago(sub.updatedAt!)}'}',
      if (u != null)
        [
          if (u.used > 0 || u.total > 0)
            u.total > 0
                ? '${formatBytes(u.used)} из ${formatBytes(u.total)}'
                : 'Использовано ${formatBytes(u.used)}',
          if (u.expire != null) 'до ${_date(u.expire!)}',
        ].join(' · '),
    ]..removeWhere((l) => l.isEmpty);
    final progress = u != null && u.total > 0
        ? (u.used / u.total).clamp(0.0, 1.0)
        : null;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 16, 12, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.rss_feed, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(sub.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              _busy
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(
                      tooltip: 'Обновить',
                      icon: const Icon(Icons.refresh),
                      onPressed: _refresh),
              IconButton(
                  tooltip: 'Удалить подписку',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _delete),
            ]),
            for (final l in lines)
              Text(l,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            if (progress != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 12),
                child: LinearProgressIndicator(
                    value: progress, minHeight: 4,
                    borderRadius: BorderRadius.circular(2)),
              ),
            if (sub.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 12),
                child: Text(sub.lastError!,
                    style: TextStyle(fontSize: 12, color: cs.error)),
              ),
          ],
        ),
      ),
    );
  }
}

class EmptyServers extends StatelessWidget {
  final VoidCallback onAdd;
  const EmptyServers({super.key, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined,
                size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            const Text('Серверов пока нет', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            const Text(
              'Добавьте ссылку, подписку, ключ vpn://, QR-код или файл.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Добавить сервер'),
            ),
          ],
        ),
      ),
    );
  }
}
