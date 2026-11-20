import 'package:flutter/material.dart';

import 'nodes_store.dart';
import 'screens/servers_screen.dart';
import 'vpn_controller.dart';

void main() {
  runApp(SmvApp(store: NodesStore(), vpn: VpnController()));
}

class SmvApp extends StatelessWidget {
  final NodesStore store;
  final VpnController vpn;
  const SmvApp({super.key, required this.store, required this.vpn});

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
      home: ServersScreen(store: store, vpn: vpn),
    );
  }
}
