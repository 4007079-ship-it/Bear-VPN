import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'nodes_store.dart';
import 'app_shell.dart';
import 'tray.dart';
import 'widgets/logo.dart';
import 'vpn_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  migrateWindowsData();
  final vpn = VpnController();
  final store = NodesStore();
  // Несколько серверов: берём серверы той же подписки (или ручного списка).
  vpn.poolFor = (selected) {
    final sub = store.subscriptionOf(selected);
    return sub != null
        ? store.nodesOf(sub)
        : [
            for (final n in store.nodes)
              if (store.subscriptionOf(n) == null) n
          ];
  };
  await Future.wait([
    vpn.recoverOnStartup().catchError((Object _) {}),
    vpn.loadMode(),
    store.load(),
  ]);
  runApp(SmvApp(store: store, vpn: vpn));
  await AppTray(vpn, store).init();
}

/// Windows: после переименования в «Bear VPN» данные (серверы, подписки)
/// лежат в новой папке %APPDATA%\\SMV\\Bear VPN. Переносим их из старой
/// %APPDATA%\\com.smv\\smv_vpn, если в новой ещё ничего нет.
void migrateWindowsData() {
  if (!Platform.isWindows) return;
  try {
    final appData = Platform.environment['APPDATA'];
    if (appData == null) return;
    final from = Directory('$appData\\com.smv\\smv_vpn');
    final to = Directory('$appData\\SMV\\Bear VPN');
    if (!from.existsSync()) return;
    if (to.existsSync() && to.listSync().isNotEmpty) return;
    to.createSync(recursive: true);
    for (final e in from.listSync()) {
      if (e is File) {
        e.copySync('${to.path}\\${e.uri.pathSegments.last}');
      }
    }
  } catch (_) {
    // Не удалось — серверы придётся добавить заново, работе это не мешает.
  }
}

class SmvApp extends StatefulWidget {
  final NodesStore store;
  final VpnController vpn;
  const SmvApp({super.key, required this.store, required this.vpn});

  @override
  State<SmvApp> createState() => _SmvAppState();
}

class _SmvAppState extends State<SmvApp> {
  late final AppLifecycleListener _lifecycle;
  Timer? _subsTimer;

  NodesStore get store => widget.store;
  VpnController get vpn => widget.vpn;

  @override
  void initState() {
    super.initState();
    // Подписки: проверить при запуске и затем раз в 15 минут.
    if (store.persist) {
      unawaited(store.refreshDue());
      _subsTimer = Timer.periodic(
          const Duration(minutes: 15), (_) => unawaited(store.refreshDue()));
    }
    // Закрытие окна: сначала отключаемся и возвращаем настройки прокси.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        // Окно должно закрываться всегда, даже если ядро не ответило.
        try {
          await vpn.shutdown().timeout(const Duration(seconds: 14));
        } catch (_) {}
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _subsTimer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = BearColors.yellow;
    const black = BearColors.black;
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ).copyWith(
          primary: seed,
          onPrimary: Colors.black,
          surface: black,
          surfaceContainerLowest: black,
          surfaceContainerLow: const Color(0xFF121212),
          surfaceContainer: const Color(0xFF161616),
          surfaceContainerHigh: const Color(0xFF1C1C1C),
          surfaceContainerHighest: const Color(0xFF262626),
          secondaryContainer: const Color(0xFF3A2E00),
          onSecondaryContainer: const Color(0xFFFFD54A),
          outline: const Color(0xFF5A5A5A),
          outlineVariant: const Color(0xFF2E2E2E),
        ),
        scaffoldBackgroundColor: black,
        useMaterial3: true,
      ),
      themeMode: ThemeMode.dark,
      home: AppShell(store: store, vpn: vpn),
    );
  }
}
