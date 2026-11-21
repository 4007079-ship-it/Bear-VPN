import 'package:flutter/material.dart';

import 'nodes_store.dart';
import 'screens/home_screen.dart';
import 'screens/logs_screen.dart';
import 'screens/servers_screen.dart';
import 'vpn_controller.dart';
import 'widgets/traffic_card.dart';

/// Каркас: боковое меню на широком экране (Windows), нижнее — на телефоне.
class AppShell extends StatefulWidget {
  final NodesStore store;
  final VpnController vpn;
  const AppShell({super.key, required this.store, required this.vpn});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _items = [
    (Icons.power_settings_new, 'Главная'),
    (Icons.dns_outlined, 'Серверы'),
    (Icons.article_outlined, 'Логи'),
    (Icons.info_outline, 'О программе'),
  ];

  Widget _page(bool wide) => switch (_index) {
        0 => HomeScreen(
            store: widget.store, vpn: widget.vpn, showTraffic: !wide),
        1 => ServersScreen(store: widget.store, vpn: widget.vpn),
        2 => LogsScreen(vpn: widget.vpn),
        _ => const AboutScreen(),
      };

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    if (!wide) {
      return Scaffold(
        body: _page(false),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            for (final (icon, label) in _items)
              NavigationDestination(icon: Icon(icon), label: label),
          ],
        ),
      );
    }

    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 240,
            color: cs.surfaceContainerLow,
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < _items.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: _NavTile(
                      icon: _items[i].$1,
                      label: _items[i].$2,
                      selected: _index == i,
                      onTap: () => setState(() => _index = i),
                    ),
                  ),
                const Spacer(),
                TrafficCards(vpn: widget.vpn),
              ],
            ),
          ),
          Expanded(child: _page(true)),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _NavTile(
      {required this.icon,
      required this.label,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Row(children: [
          Container(
            width: 56,
            height: 40,
            decoration: BoxDecoration(
              color: selected ? cs.secondaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(icon,
                color: selected ? cs.onSecondaryContainer : cs.onSurfaceVariant),
          ),
          const SizedBox(width: 14),
          Text(label,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
        ]),
      ),
    );
  }
}
