import 'package:flutter_test/flutter_test.dart';
import 'package:smv_link_parser/smv_link_parser.dart';
import 'package:smv_vpn/main.dart';
import 'package:smv_vpn/nodes_store.dart';

void main() {
  testWidgets('пустой список и узел после добавления', (tester) async {
    final store = NodesStore();
    await tester.pumpWidget(SmvApp(store: store));
    expect(find.text('Узлов пока нет'), findsOneWidget);

    final r = const LinkParser().parse(
        'trojan://pw@tr.example.com:443?sni=tr.example.com#Test%20node');
    store.addAll(r.nodes);
    await tester.pump();
    expect(find.text('Test node'), findsOneWidget);
    expect(find.text('Trojan'), findsOneWidget);
  });
}
