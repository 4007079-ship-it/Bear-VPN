import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smv_link_parser/smv_link_parser.dart';
import 'package:smv_vpn/main.dart';
import 'package:smv_vpn/nodes_store.dart';
import 'package:smv_vpn/vpn_controller.dart';

void main() {
  testWidgets('главная: пусто, затем сервер в списке и кнопка подключения',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = NodesStore();
    await tester.pumpWidget(SmvApp(store: store, vpn: VpnController()));
    expect(find.text('Главная'), findsWidgets);
    expect(find.text('Добавить сервер'), findsWidgets);
    expect(find.text('Текущий трафик'), findsOneWidget);

    final r = const LinkParser().parse(
        'trojan://pw@tr.example.com:443?sni=tr.example.com#Test%20node');
    store.addAll(r.nodes);
    await tester.pump();
    expect(find.text('Test node'), findsWidgets);
    expect(find.text('Нажмите для подключения'), findsOneWidget);
  });
}
