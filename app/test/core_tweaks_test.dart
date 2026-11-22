import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smv_link_parser/smv_link_parser.dart';
import 'package:smv_vpn/core_tweaks.dart';

Map<String, dynamic> outbound(String network, {String protocol = 'vless'}) => {
      'tag': 'proxy',
      'protocol': protocol,
      'settings': {'vnext': []},
      'streamSettings': {
        'network': network,
        'security': 'reality',
        if (network == 'xhttp') 'xhttpSettings': {'path': '/x'},
      },
    };

String config(Map<String, dynamic> proxy) => jsonEncode({
      'inbounds': [
        {'tag': 'socks', 'protocol': 'socks', 'port': 10808}
      ],
      'outbounds': [
        proxy,
        {'tag': 'direct', 'protocol': 'freedom'},
        {'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': {'domainStrategy': 'AsIs', 'rules': [], 'balancers': []},
    });

Map<String, dynamic> run(String c, CoreSettings s,
        [List<Map<String, dynamic>> extra = const []]) =>
    jsonDecode(applyCoreSettings(c, s, extraProxies: extra))
        as Map<String, dynamic>;

void main() {
  test('по умолчанию конфиг не меняется', () {
    final c = config(outbound('tcp'));
    expect(applyCoreSettings(c, CoreSettings()), c);
  });

  test('fragment: finalmask.tcp у прокси, direct не трогаем', () {
    final j = run(config(outbound('tcp')), CoreSettings(fragment: true));
    final outs = j['outbounds'] as List;
    final mask = outs.first['streamSettings']['finalmask']['tcp'] as List;
    expect(mask.single['type'], 'fragment');
    expect(mask.single['settings']['packets'], 'tlshello');
    expect(mask.single['settings']['lengths'], ['100-200']);
    expect(outs.firstWhere((o) => o['tag'] == 'direct')['streamSettings'],
        isNull);
  });

  test('fragment не применяется к Hysteria2', () {
    final j = run(config(outbound('hysteria', protocol: 'hysteria')),
        CoreSettings(fragment: true));
    final outs = j['outbounds'] as List;
    expect(outs.first['streamSettings']['finalmask'], isNull);
  });

  test('xmux только для xhttp', () {
    final j = run(config(outbound('xhttp')), CoreSettings(xmux: true));
    final xmux =
        (j['outbounds'] as List).first['streamSettings']['xhttpSettings']['xmux'];
    expect(xmux['maxConnections'], 6);
    expect(xmux['maxConcurrency'], 0);
    final t = run(config(outbound('tcp')), CoreSettings(xmux: true));
    expect((t['outbounds'] as List).first['streamSettings']['xhttpSettings'],
        isNull);
  });

  test('несколько серверов: теги, балансировщик, observatory', () {
    final j = run(config(outbound('tcp')), CoreSettings(multiServer: true),
        [outbound('xhttp'), outbound('tcp')]);
    final tags = [for (final o in j['outbounds'] as List) o['tag']];
    expect(tags.take(3), ['proxy', 'proxy-2', 'proxy-3']);
    expect(tags, containsAll(['direct', 'block']));
    final b = (j['routing']['balancers'] as List).single;
    expect(b['tag'], balancerTag);
    expect(b['strategy']['type'], 'leastPing');
    expect((j['routing']['rules'] as List).last['balancerTag'], balancerTag);
    expect(j['observatory']['subjectSelector'], ['proxy']);
  });

  test('несколько серверов без других серверов — без балансировщика', () {
    final j = run(config(outbound('tcp')), CoreSettings(multiServer: true));
    expect(j['routing']['balancers'], isEmpty);
    expect(j['observatory'], isNull);
  });

  test('настройки сохраняются и читаются', () {
    final s = CoreSettings(
        fragment: true,
        fragmentLength: '50-80',
        multiServer: true,
        strategy: BalanceStrategy.spread);
    final r = CoreSettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);
    expect(r.fragment, isTrue);
    expect(r.fragmentLength, '50-80');
    expect(r.strategy, BalanceStrategy.spread);
    expect(CoreSettings.fromJson({'fragment_length': 'abc'}).fragmentLength,
        '100-200');
  });

  test('IPv6 выключен: правило ::/0 в blackhole первым', () {
    final j = run(config(outbound('tcp')),
        CoreSettings(ipv6Traffic: false, multiServer: true),
        [outbound('tcp')]);
    final rules = j['routing']['rules'] as List;
    expect(rules.first['ip'], ['::/0']);
    expect(rules.first['outboundTag'], 'block');
    expect(rules.last['balancerTag'], balancerTag);
  });

  test('подключение к серверу по IPv4', () {
    final j = run(config(outbound('tcp')), CoreSettings(serverIp: ServerIp.ipv4));
    expect((j['outbounds'] as List).first['streamSettings']['sockopt']
        ['domainStrategy'], 'UseIPv4');
  });

  test('hysteria2 salamander → finalmask.udp', () {
    final node = const LinkParser()
        .parse('hysteria2://pw@1.2.3.4:443?sni=a.example.com'
            '&obfs=salamander&obfs-password=secret#H')
        .nodes
        .single;
    final c = config(outbound('hysteria', protocol: 'hysteria'));
    final j = jsonDecode(applyNodeFixups(c, node)) as Map<String, dynamic>;
    final udp = (j['outbounds'] as List).first['streamSettings']['finalmask']
        ['udp'] as List;
    expect(udp.single['type'], 'salamander');
    expect(udp.single['settings']['password'], 'secret');
  });

  test('отпечаток uTLS заменяется у Reality, у Shadowsocks не появляется', () {
    final j = run(config(outbound('tcp')), CoreSettings(fingerprint: 'firefox'));
    expect((j['outbounds'] as List).first['streamSettings']['realitySettings']
        ['fingerprint'], 'firefox');
    final ss = run(
        config({
          'tag': 'proxy',
          'protocol': 'shadowsocks',
          'settings': {},
          'streamSettings': {'network': 'tcp', 'security': 'none'},
        }),
        CoreSettings(fingerprint: 'firefox'));
    final st = (ss['outbounds'] as List).first['streamSettings'] as Map;
    expect(st.containsKey('tlsSettings'), isFalse);
    expect(st.containsKey('realitySettings'), isFalse);
  });
}
