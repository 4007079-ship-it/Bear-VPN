import 'package:flutter/material.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

import '../import_flow.dart';
import '../nodes_store.dart';
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
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: nodes.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final n = nodes[i];
                    final hasErrors =
                        validateNode(n).any((issue) => issue.isError);
                    final isActive = vpn.activeNodeId == n.id &&
                        vpn.state == VpnState.connected;
                    return ListTile(
                      selected: store.selectedId == n.id,
                      leading: IconButton(
                        tooltip: 'Выбрать',
                        icon: Icon(store.selectedId == n.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked),
                        onPressed: () => store.select(n.id),
                      ),
                      title: Text(n.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
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
                          ? Icon(Icons.bolt, color: Theme.of(context).colorScheme.primary)
                          : hasErrors
                              ? Icon(Icons.error_outline,
                                  color: Theme.of(context).colorScheme.error)
                              : const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => NodeScreen(store: store, node: n))),
                    );
                  },
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
              'Добавьте ссылку, ключ vpn://, QR-код или файл.',
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
