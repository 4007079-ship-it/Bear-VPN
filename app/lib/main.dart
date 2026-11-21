import 'dart:ui';

import 'package:flutter/material.dart';

import 'nodes_store.dart';
import 'app_shell.dart';
import 'widgets/logo.dart';
import 'vpn_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final vpn = VpnController();
  final store = NodesStore();
  await Future.wait([
    vpn.recoverOnStartup().catchError((Object _) {}),
    store.load(),
  ]);
  runApp(SmvApp(store: store, vpn: vpn));
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

  NodesStore get store => widget.store;
  VpnController get vpn => widget.vpn;

  @override
  void initState() {
    super.initState();
    // Закрытие окна: сначала отключаемся и возвращаем настройки прокси.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        // Окно должно закрываться всегда, даже если ядро не ответило.
        try {
          await vpn.shutdown().timeout(const Duration(seconds: 4));
        } catch (_) {}
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
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
