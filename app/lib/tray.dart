import 'dart:io';

import 'package:tray_manager/tray_manager.dart';

import 'nodes_store.dart';
import 'vpn_controller.dart';

/// Значок Bear в области уведомлений Windows: показывает, включён ли VPN,
/// и даёт подключиться/отключиться и выйти, не открывая окно.
class AppTray with TrayListener {
  AppTray(this.vpn, this.store);

  final VpnController vpn;
  final NodesStore store;
  VpnState? _shown;

  Future<void> init() async {
    if (!Platform.isWindows) return;
    trayManager.addListener(this);
    vpn.addListener(_onChange);
    await _update(force: true);
  }

  void _onChange() => _update();

  Future<void> _update({bool force = false}) async {
    final st = vpn.state;
    if (!force && st == _shown) return; // статистика обновляется каждую секунду
    _shown = st;
    final on = st == VpnState.connected;
    try {
      await trayManager
          .setIcon(on ? 'assets/tray_on.ico' : 'assets/tray_off.ico');
      await trayManager.setToolTip(switch (st) {
        VpnState.connected => 'Bear VPN — подключено',
        VpnState.connecting => 'Bear VPN — подключение…',
        VpnState.disconnecting => 'Bear VPN — отключение…',
        VpnState.disconnected => 'Bear VPN — не подключено',
      });
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(
          key: 'toggle',
          label: st == VpnState.disconnected ? 'Подключить' : 'Отключить',
        ),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Выход'),
      ]));
    } catch (_) {
      // значок в трее необязателен — без него приложение работает
    }
  }

  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'toggle':
        if (vpn.state == VpnState.disconnected) {
          final node = store.nodes
              .where((n) => n.id == store.selectedId)
              .firstOrNull;
          if (node != null) await vpn.connect(node);
        } else {
          await vpn.disconnect();
        }
      case 'exit':
        try {
          await vpn.shutdown().timeout(const Duration(seconds: 4));
        } catch (_) {}
        await trayManager.destroy();
        exit(0);
    }
  }
}
