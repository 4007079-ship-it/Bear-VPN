import 'dart:ui';

import 'package:flutter/material.dart';

import 'nodes_store.dart';
import 'app_shell.dart';
import 'vpn_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final vpn = VpnController();
  await vpn.recoverOnStartup();
  runApp(SmvApp(store: NodesStore(), vpn: vpn));
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
        await vpn.shutdown();
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
    final seed = const Color(0xFF2F6FED);
    return MaterialApp(
      title: 'SMV-VPN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.dark,
      home: AppShell(store: store, vpn: vpn),
    );
  }
}
