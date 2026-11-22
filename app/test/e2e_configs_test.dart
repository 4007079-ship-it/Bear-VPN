// Генерация конфигов Xray для сквозной проверки (tools/e2e/run.sh).
// Обычный `flutter test` этот файл пропускает: нужен E2E_LINKS.
//
// Путь тот же, что в приложении: ссылка → наш парсер → nodeToUri →
// FlutterVless.parseFromURL → applyCoreSettings.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:smv_link_parser/smv_link_parser.dart';
import 'package:smv_vpn/core_tweaks.dart';

void main() {
  final linksPath = Platform.environment['E2E_LINKS'];
  final outDir = Platform.environment['E2E_OUT'];

  test('сквозные конфиги', () {
    if (linksPath == null || outDir == null) {
      markTestSkipped('E2E_LINKS не задан');
      return;
    }
    final out = Directory(outDir)..createSync(recursive: true);
    final nodes = <String, ProxyNode>{};
    for (final line in File(linksPath).readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final r = const LinkParser().parse(line.trim());
      expect(r.nodes, hasLength(1), reason: 'не разобрана: ${line.split('#').last}');
      final n = r.nodes.single;
      for (final i in validateNode(n)) {
        // ignore: avoid_print
        print('  ${n.name}: ${i.isError ? 'ОШИБКА' : 'предупреждение'} ${i.message}');
      }
      nodes[n.name] = n;
    }

    String base(ProxyNode n) => applyNodeFixups(
        FlutterVless.parseFromURL(nodeToUri(n)).getFullConfiguration(), n);
    Map<String, dynamic> firstOutbound(ProxyNode n) =>
        ((jsonDecode(base(n)) as Map)['outbounds'] as List).first
            as Map<String, dynamic>;

    void write(String name, String config) {
      File('${out.path}/$name.json').writeAsStringSync(config);
    }

    // 1. Каждый сервер как есть (настройки по умолчанию).
    for (final e in nodes.entries) {
      write('plain__${e.key}', base(e.value));
    }

    ProxyNode node(String name) =>
        nodes[name] ?? (throw StateError('нет узла $name'));

    // 2. Настройки по одной.
    write(
        'fragment__reality-tcp',
        applyCoreSettings(base(node('reality-tcp')), CoreSettings(fragment: true)));
    write(
        'fragment__trojan-tls',
        applyCoreSettings(base(node('trojan-tls')), CoreSettings(fragment: true)));
    write(
        'fragment__hy2',
        applyCoreSettings(base(node('hy2')), CoreSettings(fragment: true)));
    write(
        'xmux__reality-xhttp',
        applyCoreSettings(base(node('reality-xhttp')), CoreSettings(xmux: true)));
    write(
        'ipv6off__reality-tcp',
        applyCoreSettings(
            base(node('reality-tcp')), CoreSettings(ipv6Traffic: false)));
    write(
        'serverip4__reality-tcp',
        applyCoreSettings(
            base(node('reality-tcp')), CoreSettings(serverIp: ServerIp.ipv4)));

    // 3. Несколько серверов.
    final extras = [
      firstOutbound(node('reality-tcp-2')),
      firstOutbound(node('trojan-tls')),
      firstOutbound(node('hy2')),
    ];
    for (final st in BalanceStrategy.values) {
      write(
          'multi-${st.name}__reality-tcp',
          applyCoreSettings(base(node('reality-tcp')),
              CoreSettings(multiServer: true, strategy: st),
              extraProxies: extras));
    }
    // Основной сервер мёртв — трафик должен уйти на живые.
    if (nodes.containsKey('dead')) {
      write(
          'multi-fastest__dead-first',
          applyCoreSettings(base(node('dead')),
              CoreSettings(multiServer: true), extraProxies: extras));
    }

    // 4. Всё сразу.
    write(
        'all-on__reality-xhttp',
        applyCoreSettings(
            base(node('reality-xhttp')),
            CoreSettings(
                fragment: true,
                xmux: true,
                ipv6Traffic: false,
                multiServer: true),
            extraProxies: extras));
  });
}
