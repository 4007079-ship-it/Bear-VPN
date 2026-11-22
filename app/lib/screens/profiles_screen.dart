import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

import '../import_flow.dart';
import '../nodes_store.dart';
import '../subscription.dart';
import '../vpn_controller.dart';
import '../widgets/node_info.dart';
import 'node_screen.dart';

/// Профиль: подписка или «Мои серверы» (добавленные вручную).
class _Profile {
  final Subscription? sub;
  final List<ProxyNode> nodes;
  const _Profile(this.sub, this.nodes);

  String get name => sub?.name ?? 'Мои серверы';
}

List<_Profile> _profiles(NodesStore store) => [
      for (final s in store.subscriptions) _Profile(s, store.nodesOf(s)),
      if (store.manualNodes.isNotEmpty) _Profile(null, store.manualNodes),
    ];

String _two(int v) => v.toString().padLeft(2, '0');
String _date(DateTime d) {
  final l = d.toLocal();
  return '${_two(l.day)}.${_two(l.month)}.${l.year}';
}

String _ago(DateTime d) {
  final m = DateTime.now().difference(d).inMinutes;
  if (m < 1) return 'только что';
  if (m < 60) return '$m мин назад';
  if (m < 60 * 24) return '${m ~/ 60} ч назад';
  return _date(d);
}

String _servers(int n) {
  final m10 = n % 10, m100 = n % 100;
  final w = (m10 == 1 && m100 != 11)
      ? 'сервер'
      : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
          ? 'сервера'
          : 'серверов';
  return '$n $w';
}

/// Строки под названием профиля: серверы, обновление, трафик, срок.
List<String> _profileInfo(_Profile p) {
  final s = p.sub;
  final u = s?.usage;
  return [
    [
      _servers(p.nodes.length),
      if (s != null)
        s.updatedAt == null ? 'не обновлялся' : 'обновлён ${_ago(s.updatedAt!)}',
    ].join(' · '),
    if (u != null)
      [
        if (u.used > 0 || u.total > 0)
          u.total > 0
              ? '${formatBytes(u.used)} из ${formatBytes(u.total)}'
              : 'использовано ${formatBytes(u.used)}',
        if (u.expire != null) 'до ${_date(u.expire!)}',
      ].join(' · '),
  ]..removeWhere((l) => l.isEmpty);
}

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// Вкладка «Профили» (как в Hiddify): подписки и «Мои серверы».
class ProfilesScreen extends StatelessWidget {
  final NodesStore store;
  final VpnController vpn;
  const ProfilesScreen({super.key, required this.store, required this.vpn});

  Future<void> _refreshAll(BuildContext context) async {
    var ok = 0;
    for (final s in store.subscriptions) {
      if (await store.refreshSubscription(s)) ok++;
    }
    if (context.mounted) {
      _snack(context, 'Обновлено профилей: $ok из ${store.subscriptions.length}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, vpn]),
      builder: (context, _) {
        final profiles = _profiles(store);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Профили'),
            actions: [
              if (store.subscriptions.isNotEmpty)
                IconButton(
                  tooltip: 'Обновить все подписки',
                  icon: const Icon(Icons.update),
                  onPressed: () => _refreshAll(context),
                ),
              IconButton(
                tooltip: 'Добавить',
                icon: const Icon(Icons.add),
                onPressed: () => ImportFlow.show(context, store),
              ),
            ],
          ),
          body: profiles.isEmpty
              ? EmptyServers(onAdd: () => ImportFlow.show(context, store))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    for (final p in profiles)
                      _ProfileCard(store: store, vpn: vpn, profile: p),
                  ],
                ),
        );
      },
    );
  }
}

class _ProfileCard extends StatefulWidget {
  final NodesStore store;
  final VpnController vpn;
  final _Profile profile;
  const _ProfileCard(
      {required this.store, required this.vpn, required this.profile});

  @override
  State<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<_ProfileCard> {
  bool _busy = false;

  Future<void> _refresh() async {
    final sub = widget.profile.sub;
    if (sub == null) return;
    setState(() => _busy = true);
    final ok = await widget.store.refreshSubscription(sub);
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(context,
        ok ? 'Обновлено: ${_servers(widget.store.nodesOf(sub).length)}' : sub.lastError ?? 'Ошибка обновления');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = widget.profile;
    final active = p.nodes.any((n) => n.id == widget.store.selectedId);
    final u = p.sub?.usage;
    final progress =
        u != null && u.total > 0 ? (u.used / u.total).clamp(0.0, 1.0) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: active ? cs.secondaryContainer : cs.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
              color: active ? cs.primary : cs.outlineVariant, width: active ? 1.5 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ProfileScreen(
                  store: widget.store, vpn: widget.vpn, sub: p.sub))),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ProfileMenu(store: widget.store, profile: p, onRefresh: _refresh),
                VerticalDivider(width: 1, color: cs.outlineVariant),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        for (final l in _profileInfo(p))
                          Text(l,
                              style: TextStyle(
                                  fontSize: 12, color: cs.onSurfaceVariant)),
                        if (progress != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6, right: 8),
                            child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 4,
                                borderRadius: BorderRadius.circular(2)),
                          ),
                        if (p.sub?.lastError != null)
                          Text(p.sub!.lastError!,
                              style: TextStyle(fontSize: 12, color: cs.error)),
                      ],
                    ),
                  ),
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                        child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// «⋮» профиля: Обновить, Поделиться ▸, Изменить, Удалить.
class _ProfileMenu extends StatelessWidget {
  final NodesStore store;
  final _Profile profile;
  final VoidCallback onRefresh;
  const _ProfileMenu(
      {required this.store, required this.profile, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final sub = profile.sub;
    return MenuAnchor(
      menuChildren: [
        if (sub != null)
          MenuItemButton(
            leadingIcon: const Icon(Icons.refresh),
            onPressed: onRefresh,
            child: const Text('Обновить'),
          ),
        SubmenuButton(
          leadingIcon: const Icon(Icons.share_outlined),
          menuChildren: [
            if (sub != null) ...[
              MenuItemButton(
                leadingIcon: const Icon(Icons.link),
                onPressed: () => _copySubscription(context, sub),
                child: const Text('Скопировать ссылку подписки'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.qr_code_2),
                onPressed: () => _qrSubscription(context, sub),
                child: const Text('QR-код подписки'),
              ),
            ] else
              MenuItemButton(
                leadingIcon: const Icon(Icons.copy_all),
                onPressed: () => _copyAll(context),
                child: const Text('Скопировать все ссылки'),
              ),
          ],
          child: const Text('Поделиться'),
        ),
        if (sub != null)
          MenuItemButton(
            leadingIcon: const Icon(Icons.edit_outlined),
            onPressed: () => _edit(context, sub),
            child: const Text('Изменить'),
          ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.delete_outline),
          onPressed: () => _delete(context),
          child: const Text('Удалить'),
        ),
      ],
      builder: (context, controller, _) => InkWell(
        onTap: () =>
            controller.isOpen ? controller.close() : controller.open(),
        child: const SizedBox(
          width: 48,
          child: Center(child: Icon(Icons.more_vert)),
        ),
      ),
    );
  }

  Future<bool> _confirmSecret(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('В ссылке — личный токен'),
        content: const Text(
            'Любой, у кого есть ссылка подписки, получит все её серверы. '
            'Передавайте её только тем, кому доверяете.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Продолжить')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _copySubscription(BuildContext context, Subscription sub) async {
    if (!await _confirmSecret(context)) return;
    await Clipboard.setData(ClipboardData(text: sub.url));
    if (context.mounted) _snack(context, 'Ссылка подписки скопирована');
  }

  Future<void> _qrSubscription(BuildContext context, Subscription sub) async {
    if (!await _confirmSecret(context) || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(sub.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        content: Container(
          color: Colors.white,
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: 280,
            height: 280,
            child: QrImageView(
                data: sub.url, size: 280, backgroundColor: Colors.white),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Закрыть')),
        ],
      ),
    );
  }

  Future<void> _copyAll(BuildContext context) async {
    final text = profile.nodes.map(shareUri).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      _snack(context, 'Скопировано: ${_servers(profile.nodes.length)}');
    }
  }

  Future<void> _edit(BuildContext context, Subscription sub) async {
    final name = TextEditingController(text: sub.name);
    var hours = sub.intervalHours;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Изменить профиль'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                      labelText: 'Название', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  const Expanded(child: Text('Обновлять каждые')),
                  DropdownButton<int>(
                    value: const [1, 3, 6, 12, 24, 48].contains(hours) ? hours : 12,
                    items: [
                      for (final h in const [1, 3, 6, 12, 24, 48])
                        DropdownMenuItem(value: h, child: Text('$h ч')),
                    ],
                    onChanged: (v) => setState(() => hours = v ?? hours),
                  ),
                ]),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отмена')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Сохранить')),
          ],
        ),
      ),
    );
    if (ok == true) {
      store.updateSubscription(sub, name: name.text, intervalHours: hours);
    }
  }

  Future<void> _delete(BuildContext context) async {
    final sub = profile.sub;
    if (sub == null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Удалить «Мои серверы»?'),
          content: Text('Будут удалены ${_servers(profile.nodes.length)}, '
              'добавленные вручную.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отмена')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Удалить')),
          ],
        ),
      );
      if (ok == true) store.removeManual();
      return;
    }
    final keep = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Удалить профиль «${sub.name}»?'),
        content: const Text('Серверы подписки можно удалить вместе с ней '
            'или оставить в «Моих серверах» (без обновления).'),
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
    if (keep != null) store.removeSubscription(sub, keepNodes: keep);
  }
}

/// Внутри профиля: его серверы, у каждого — «⋮».
class ProfileScreen extends StatelessWidget {
  final NodesStore store;
  final VpnController vpn;
  final Subscription? sub;
  const ProfileScreen(
      {super.key, required this.store, required this.vpn, this.sub});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, vpn]),
      builder: (context, _) {
        final s = sub;
        final exists = s == null || store.subscriptions.contains(s);
        final nodes =
            !exists ? const <ProxyNode>[] : (s == null ? store.manualNodes : store.nodesOf(s));
        final profile = _Profile(s, nodes);
        final cs = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(
            title: Text(profile.name),
            actions: [
              if (s != null && exists)
                IconButton(
                  tooltip: 'Обновить',
                  icon: const Icon(Icons.refresh),
                  onPressed: () async {
                    final ok = await store.refreshSubscription(s);
                    if (context.mounted) {
                      _snack(context, ok ? 'Обновлено' : s.lastError ?? 'Ошибка');
                    }
                  },
                ),
            ],
          ),
          body: nodes.isEmpty
              ? Center(
                  child: Text('В профиле нет серверов',
                      style: TextStyle(color: cs.onSurfaceVariant)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                  children: [
                    for (final l in _profileInfo(profile))
                      Text(l,
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant)),
                    const SizedBox(height: 10),
                    for (final n in nodes)
                      _ServerCard(store: store, vpn: vpn, node: n),
                  ],
                ),
        );
      },
    );
  }
}

class _ServerCard extends StatelessWidget {
  final NodesStore store;
  final VpnController vpn;
  final ProxyNode node;
  const _ServerCard(
      {required this.store, required this.vpn, required this.node});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final n = node;
    final selected = store.selectedId == n.id;
    final active = vpn.activeNodeId == n.id && vpn.state == VpnState.connected;
    final hasErrors = validateNode(n).any((i) => i.isError);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? cs.secondaryContainer : cs.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
              color: selected ? cs.primary : cs.outlineVariant,
              width: selected ? 1.5 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => store.select(n.id),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ServerMenu(store: store, node: n),
                VerticalDivider(width: 1, color: cs.outlineVariant),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(n.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w500)),
                        const SizedBox(height: 4),
                        Row(children: [
                          ProtocolChip(n.protocol),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(nodeSubtitle(n),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12, color: cs.onSurfaceVariant)),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    child: active
                        ? Icon(Icons.bolt, color: cs.primary)
                        : hasErrors
                            ? Icon(Icons.error_outline, color: cs.error)
                            : selected
                                ? Icon(Icons.check_circle, color: cs.primary)
                                : const SizedBox(width: 24),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// «⋮» сервера: Поделиться ▸, Изменить, Подробнее, Удалить.
class _ServerMenu extends StatelessWidget {
  final NodesStore store;
  final ProxyNode node;
  const _ServerMenu({required this.store, required this.node});

  @override
  Widget build(BuildContext context) {
    final fromSub = store.subscriptionOf(node) != null;
    return MenuAnchor(
      menuChildren: [
        SubmenuButton(
          leadingIcon: const Icon(Icons.share_outlined),
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.link),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: shareUri(node)));
                if (context.mounted) _snack(context, 'Ссылка скопирована');
              },
              child: const Text('Скопировать ссылку'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.qr_code_2),
              onPressed: () => shareNode(context, node),
              child: const Text('QR-код'),
            ),
          ],
          child: const Text('Поделиться'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.edit_outlined),
          onPressed: () => _rename(context),
          child: const Text('Изменить'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.info_outline),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => NodeScreen(store: store, node: node))),
          child: const Text('Подробнее'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.delete_outline),
          onPressed: () => _delete(context, fromSub),
          child: const Text('Удалить'),
        ),
      ],
      builder: (context, controller, _) => InkWell(
        onTap: () =>
            controller.isOpen ? controller.close() : controller.open(),
        child: const SizedBox(
          width: 44,
          child: Center(child: Icon(Icons.more_vert)),
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final c = TextEditingController(text: node.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Название сервера'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, c.text),
              child: const Text('Сохранить')),
        ],
      ),
    );
    if (name != null) store.renameNode(node.id, name);
  }

  Future<void> _delete(BuildContext context, bool fromSub) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Удалить «${node.name}»?'),
        content: fromSub
            ? const Text('Сервер из подписки вернётся при её следующем '
                'обновлении.')
            : null,
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) store.remove(node.id);
  }
}

/// Пустой список: подсказка и кнопка добавления.
class EmptyServers extends StatelessWidget {
  final VoidCallback onAdd;
  const EmptyServers({super.key, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.view_list_outlined, size: 56, color: cs.onSurfaceVariant),
            const SizedBox(height: 12),
            const Text('Профилей пока нет', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 6),
            Text('Добавьте ссылку, подписку, ключ vpn://, QR-код или файл.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Добавить'),
            ),
          ],
        ),
      ),
    );
  }
}
