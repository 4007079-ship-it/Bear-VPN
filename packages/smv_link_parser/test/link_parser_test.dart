import 'dart:convert';

import 'package:smv_link_parser/smv_link_parser.dart';
import 'package:test/test.dart';

const uuid = 'b831381d-6324-4d53-ad4f-8cda48b30811';
const pbk = 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0';

const vlessReality = 'vless://$uuid@example.com:443'
    '?encryption=none&flow=xtls-rprx-vision&security=reality'
    '&sni=www.microsoft.com&fp=chrome&pbk=$pbk&sid=6ba85179e30d4fc2'
    '&type=tcp#My%20VLESS%20Reality';

const hy2 = 'hysteria2://p%40ss+word@hy.example.com:443,20000-30000/'
    '?sni=hy.example.com&obfs=salamander&obfs-password=secret'
    '&up=50%20mbps&down=200#HY2%20%F0%9F%87%B3%F0%9F%87%B1';

const parser = LinkParser();

ProxyNode single(String input) {
  final r = parser.parse(input);
  expect(r.issues, isEmpty, reason: r.issues.join('\n'));
  expect(r.nodes, hasLength(1));
  return r.nodes.single;
}

/// Сравнение без id и source — они меняются при каждом импорте.
Map<String, Object?> essence(ProxyNode n) =>
    n.toJson()..remove('id')..remove('source');

void main() {
  group('URI', () {
    test('VLESS Reality', () {
      final n = single(vlessReality);
      expect(n.protocol, ProxyProtocol.vless);
      expect(n.name, 'My VLESS Reality');
      expect(n.server, 'example.com');
      expect(n.port, 443);
      expect(n.uuid, uuid);
      expect(n.flow, 'xtls-rprx-vision');
      expect(n.transport.type, 'tcp');
      expect(n.security.type, 'reality');
      expect(n.security.sni, 'www.microsoft.com');
      expect(n.security.fingerprint, 'chrome');
      expect(n.security.publicKey, pbk);
      expect(n.security.shortId, '6ba85179e30d4fc2');
      expect(n.source.raw, vlessReality);
      expect(n.source.type, SourceType.uri);
      expect(validateNode(n).where((i) => i.isError), isEmpty);
    });

    test('VLESS ws + tls, IPv6, имя с пробелами без кодирования', () {
      final n = single('vless://$uuid@[2001:db8::1]:8443?security=tls'
          '&type=ws&host=cdn.example.com&path=%2Fws%3Fed%3D2048'
          '&alpn=h2,http/1.1#Узел 1 🇩🇪');
      expect(n.server, '2001:db8::1');
      expect(n.port, 8443);
      expect(n.transport.type, 'ws');
      expect(n.transport.host, 'cdn.example.com');
      expect(n.transport.path, '/ws?ed=2048');
      expect(n.security.alpn, ['h2', 'http/1.1']);
      expect(n.name, 'Узел 1 🇩🇪');
      expect(n.address, '[2001:db8::1]:8443');
    });

    test('Hysteria2: port hopping, obfs, + в пароле не превращается в пробел',
        () {
      final n = single(hy2);
      expect(n.protocol, ProxyProtocol.hysteria2);
      expect(n.password, 'p@ss+word');
      expect(n.port, 443);
      expect(n.portRange, '443,20000-30000');
      expect(n.obfs, 'salamander');
      expect(n.obfsPassword, 'secret');
      expect(n.upMbps, 50);
      expect(n.downMbps, 200);
      expect(n.security.type, 'tls');
      expect(n.name, 'HY2 🇳🇱');
    });

    test('hy2:// — алиас Hysteria2', () {
      final n = single('hy2://pass@1.2.3.4:8443?insecure=1#x');
      expect(n.protocol, ProxyProtocol.hysteria2);
      expect(n.security.insecure, isTrue);
      expect(validateNode(n).map((i) => i.code),
          contains(ValidationCode.insecureTls));
    });

    test('TUIC', () {
      final n = single('tuic://$uuid:pa55@tuic.example.com:443'
          '?congestion_control=bbr&alpn=h3&sni=tuic.example.com'
          '&udp_relay_mode=native#TUIC');
      expect(n.protocol, ProxyProtocol.tuic);
      expect(n.uuid, uuid);
      expect(n.password, 'pa55');
      expect(n.congestionControl, 'bbr');
      expect(n.udpRelayMode, 'native');
      expect(n.security.alpn, ['h3']);
    });

    test('Trojan: TLS по умолчанию, grpc', () {
      final n = single('trojan://secret@tr.example.com:443'
          '?type=grpc&serviceName=gun&sni=tr.example.com#TR');
      expect(n.protocol, ProxyProtocol.trojan);
      expect(n.password, 'secret');
      expect(n.security.type, 'tls');
      expect(n.transport.type, 'grpc');
      expect(n.transport.serviceName, 'gun');
    });

    test('Shadowsocks SIP002 (base64url userinfo) + plugin', () {
      final info = base64Url
          .encode(utf8.encode('chacha20-ietf-poly1305:pass/word'))
          .replaceAll('=', '');
      final n = single('ss://$info@ss.example.com:8388/'
          '?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dex.com#SS');
      expect(n.method, 'chacha20-ietf-poly1305');
      expect(n.password, 'pass/word');
      expect(n.plugin, 'obfs-local');
      expect(n.pluginOpts, 'obfs=http;obfs-host=ex.com');
      expect(n.name, 'SS');
    });

    test('Shadowsocks 2022, открытый userinfo', () {
      final n = single('ss://2022-blake3-aes-128-gcm:'
          'YctPZ6U7xPPcU%2Bgp3u%2B0tx%2FtRizJN9K8y%2BuKlW2qjlI%3D'
          '@ss.example.com:443#SS22');
      expect(n.method, '2022-blake3-aes-128-gcm');
      expect(n.password, 'YctPZ6U7xPPcU+gp3u+0tx/tRizJN9K8y+uKlW2qjlI=');
      expect(validateNode(n).where((i) => i.isError), isEmpty);
    });

    test('Shadowsocks legacy: ss://BASE64(method:pass@host:port)', () {
      final b = base64.encode(utf8.encode('aes-256-gcm:p@ss@10.0.0.1:8388'));
      final n = single('ss://$b#Legacy');
      expect(n.method, 'aes-256-gcm');
      expect(n.password, 'p@ss');
      expect(n.server, '10.0.0.1');
      expect(n.port, 8388);
      expect(n.name, 'Legacy');
    });

    test('VMess (v2rayN base64 JSON)', () {
      final j = jsonEncode({
        'v': '2',
        'ps': 'VM',
        'add': 'vm.example.com',
        'port': '443',
        'id': uuid,
        'aid': '0',
        'net': 'ws',
        'type': 'none',
        'host': 'vm.example.com',
        'path': '/v',
        'tls': 'tls',
        'sni': 'vm.example.com',
      });
      final n = single('vmess://${base64.encode(utf8.encode(j))}');
      expect(n.protocol, ProxyProtocol.vmess);
      expect(n.name, 'VM');
      expect(n.port, 443);
      expect(n.transport.type, 'ws');
      expect(n.transport.path, '/v');
      expect(n.security.type, 'tls');
    });

    test('socks с base64 userinfo (v2rayN) и http-прокси', () {
      final s = single(
          'socks://${base64.encode(utf8.encode('user:pw'))}@1.1.1.1:1080#S');
      expect(s.protocol, ProxyProtocol.socks);
      expect(s.username, 'user');
      expect(s.password, 'pw');
      final h = single('http://u:p@10.0.0.2:3128');
      expect(h.protocol, ProxyProtocol.http);
      expect(h.username, 'u');
    });
  });

  group('Составные форматы', () {
    test('Base64-подписка с несколькими URI', () {
      final sub = base64.encode(utf8.encode(
          '$vlessReality\r\n$hy2\n\ntrojan://pw@t.example.com:443#T\n'));
      final r = parser.parse(sub, sourceType: SourceType.subscription);
      expect(r.format, InputFormat.base64Subscription);
      expect(r.nodes, hasLength(3));
      expect(r.issues, isEmpty);
      expect(r.nodes.every((n) => n.source.type == SourceType.subscription),
          isTrue);
      // source.raw — ссылка конкретного узла, а не вся подписка.
      expect(r.nodes.first.source.raw, vlessReality);
    });

    test('Base64 URL-safe без padding', () {
      final sub = base64Url
          .encode(utf8.encode('$vlessReality\n$hy2'))
          .replaceAll('=', '');
      expect(parser.parse(sub).nodes, hasLength(2));
    });

    test('Голый список: пробелы, запятые, \\r\\n', () {
      final r = parser.parse(
          '$vlessReality $hy2,trojan://pw@t.example.com:443#T\r\n'
          'ssr://abc');
      expect(r.format, InputFormat.uriList);
      expect(r.nodes, hasLength(3));
      expect(r.issues.single.code, ParseErrorCode.unsupportedProtocol);
      expect(r.issues.single.index, 3);
    });

    test('Дубликаты внутри импорта схлопываются', () {
      final r = parser.parse('$vlessReality\n$vlessReality');
      expect(r.nodes, hasLength(1));
    });

    test('sing-box JSON', () {
      final cfg = jsonEncode({
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'sb-reality',
            'server': 'example.com',
            'server_port': 443,
            'uuid': uuid,
            'flow': 'xtls-rprx-vision',
            'tls': {
              'enabled': true,
              'server_name': 'www.microsoft.com',
              'utls': {'enabled': true, 'fingerprint': 'chrome'},
              'reality': {
                'enabled': true,
                'public_key': pbk,
                'short_id': 'ab'
              },
            },
          },
          {
            'type': 'hysteria2',
            'tag': 'sb-hy2',
            'server': 'hy.example.com',
            'server_ports': ['20000:30000'],
            'password': 'pw',
            'tls': {'enabled': true, 'server_name': 'hy.example.com'},
          },
          {'type': 'wireguard', 'tag': 'wg', 'server': 'w', 'server_port': 1},
          {'type': 'direct', 'tag': 'direct'},
          {'type': 'selector', 'tag': 'proxy', 'outbounds': ['sb-reality']},
        ],
      });
      final r = parser.parse(cfg, sourceType: SourceType.file);
      expect(r.format, InputFormat.singBoxJson);
      expect(r.nodes.map((n) => n.name), ['sb-reality', 'sb-hy2']);
      final v = r.nodes.first;
      expect(v.security.type, 'reality');
      expect(v.security.publicKey, pbk);
      expect(v.security.fingerprint, 'chrome');
      final h = r.nodes[1];
      expect(h.port, 20000);
      expect(h.portRange, '20000-30000');
      expect(r.issues.single.code, ParseErrorCode.unsupportedProtocol);
      expect(r.issues.single.kind, 'sing-box:wireguard');
    });

    test('Xray JSON', () {
      final cfg = jsonEncode({
        'outbounds': [
          {
            'protocol': 'vless',
            'tag': 'xr',
            'settings': {
              'vnext': [
                {
                  'address': 'example.com',
                  'port': 443,
                  'users': [
                    {'id': uuid, 'encryption': 'none', 'flow': ''}
                  ],
                }
              ],
            },
            'streamSettings': {
              'network': 'xhttp',
              'security': 'reality',
              'realitySettings': {
                'serverName': 'www.microsoft.com',
                'publicKey': pbk,
                'shortId': 'ab',
                'fingerprint': 'chrome',
              },
              'xhttpSettings': {'path': '/x', 'mode': 'auto'},
            },
          },
          {
            'protocol': 'shadowsocks',
            'settings': {
              'servers': [
                {
                  'address': '1.2.3.4',
                  'port': 8388,
                  'method': 'aes-128-gcm',
                  'password': 'pw'
                }
              ],
            },
          },
          {'protocol': 'freedom', 'tag': 'direct'},
        ],
      });
      final r = parser.parse(cfg);
      expect(r.format, InputFormat.xrayJson);
      expect(r.issues, isEmpty);
      expect(r.nodes, hasLength(2));
      expect(r.nodes.first.transport.type, 'xhttp');
      expect(r.nodes.first.transport.mode, 'auto');
      expect(r.nodes.first.flow, isNull);
      expect(r.nodes[1].name, '1.2.3.4:8388');
    });

    test('Clash YAML', () {
      const yaml = '''
mixed-port: 7890
proxies:
  - name: "clash-vless"
    type: vless
    server: example.com
    port: 443
    uuid: $uuid
    network: grpc
    tls: true
    servername: www.microsoft.com
    client-fingerprint: chrome
    reality-opts:
      public-key: $pbk
      short-id: ab
    grpc-opts:
      grpc-service-name: gun
  - name: clash-ss
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-256-gcm
    password: "pw"
  - name: clash-hy2
    type: hysteria2
    server: hy.example.com
    port: 443
    password: pw
    up: "30 Mbps"
    down: "100 Mbps"
  - name: old
    type: ssr
    server: 1.1.1.1
    port: 1
proxy-groups: []
''';
      final r = parser.parse(yaml);
      expect(r.format, InputFormat.clashYaml);
      expect(r.nodes.map((n) => n.name),
          ['clash-vless', 'clash-ss', 'clash-hy2']);
      expect(r.nodes.first.security.type, 'reality');
      expect(r.nodes.first.transport.serviceName, 'gun');
      expect(r.nodes[2].upMbps, 30);
      expect(r.issues.single.kind, 'clash:ssr');
    });
  });

  group('Ошибки', () {
    test('пустой ввод', () {
      final r = parser.parse('   \n ');
      expect(r.format, InputFormat.empty);
      expect(r.issues.single.code, ParseErrorCode.empty);
    });

    test('мусор', () {
      final r = parser.parse('привет, это не ключ');
      expect(r.isFailure, isTrue);
      expect(r.issues.single.code, ParseErrorCode.unrecognized);
    });

    test('неподдерживаемый протокол', () {
      final r = parser.parse('wireguard://abc@1.2.3.4:51820');
      expect(r.issues.single.code, ParseErrorCode.unsupportedProtocol);
      expect(r.issues.single.message, contains('не поддерживается'));
    });

    test('битая ссылка: нет порта — без падения, без секретов в ошибке', () {
      final r = parser.parse('vless://$uuid@example.com?security=tls');
      expect(r.nodes, isEmpty);
      expect(r.issues.single.code, ParseErrorCode.missingField);
      expect(r.issues.single.toString(), isNot(contains(uuid)));
    });

    test('битый JSON', () {
      final r = parser.parse('{"outbounds": [');
      expect(r.issues.single.code, ParseErrorCode.malformed);
    });

    test('https:// — URL подписки, а не узел', () {
      final r = parser.parse('https://sub.example.com/api/v1/client/abc');
      expect(r.format, InputFormat.subscriptionUrl);
      expect(r.nodes, isEmpty);
      expect(r.subscriptionUrls, ['https://sub.example.com/api/v1/client/abc']);
    });
  });

  group('Валидация', () {
    test('Reality без sni и pbk — ошибки', () {
      final n = single('vless://$uuid@example.com:443?security=reality#x');
      final codes = validateNode(n).where((i) => i.isError).map((i) => i.code);
      expect(codes, containsAll([
        ValidationCode.realityMissingSni,
        ValidationCode.realityMissingPublicKey,
      ]));
    });

    test('flow с ws — ошибка', () {
      final n = single('vless://$uuid@example.com:443'
          '?security=tls&type=ws&flow=xtls-rprx-vision#x');
      expect(validateNode(n).map((i) => i.code),
          contains(ValidationCode.invalidFlow));
    });

    test('неподдерживаемый транспорт и шифр', () {
      final n = single('vless://$uuid@example.com:443?type=kcp#x');
      expect(validateNode(n).map((i) => i.code),
          contains(ValidationCode.unsupportedTransport));
      final ss = single('ss://${base64.encode(utf8.encode('bf-cfb:pw'))}'
          '@1.2.3.4:1#x');
      expect(validateNode(ss).map((i) => i.code),
          contains(ValidationCode.unsupportedCipher));
    });
  });

  group('Экспорт / QR round-trip', () {
    final links = [
      vlessReality,
      hy2,
      'vless://$uuid@[2001:db8::1]:8443?security=tls&type=ws'
          '&host=cdn.example.com&path=%2Fws&alpn=h2,http/1.1#WS',
      'tuic://$uuid:pa55@tuic.example.com:443?congestion_control=bbr'
          '&alpn=h3&sni=tuic.example.com#TUIC',
      'trojan://secret@tr.example.com:443?type=grpc&serviceName=gun'
          '&sni=tr.example.com#TR',
      'ss://2022-blake3-aes-128-gcm:YctPZ6U7xPPcU%2Bgp3u%2B0tx%2FtRizJN9K8y'
          '%2BuKlW2qjlI%3D@ss.example.com:443#SS22',
      'ss://${base64Url.encode(utf8.encode('aes-256-gcm:pw'))}'
          '@1.2.3.4:8388/?plugin=v2ray-plugin%3Bmode%3Dwebsocket#SSp',
      'socks://u:p@1.1.1.1:1080#S',
    ];

    for (final link in links) {
      test(link.substring(0, link.indexOf('://')), () {
        final a = single(link);
        final uri = nodeToUri(a);
        final b = single(uri);
        expect(essence(b), essence(a), reason: uri);
      });
    }

    test('VMess round-trip', () {
      final a = single('vmess://$uuid@vm.example.com:443'
          '?type=grpc&serviceName=gun&security=tls&sni=vm.example.com#VM');
      final b = single(nodeToUri(a));
      expect(essence(b), essence(a));
    });

    test('Узел из sing-box JSON экспортируется ссылкой', () {
      final cfg = jsonEncode({
        'outbounds': [
          {
            'type': 'trojan',
            'tag': 'sb',
            'server': 'tr.example.com',
            'server_port': 443,
            'password': 'pw',
            'tls': {'enabled': true, 'server_name': 'tr.example.com'},
          }
        ]
      });
      final n = parser.parse(cfg).nodes.single;
      final uri = shareUri(n);
      expect(uri, startsWith('trojan://pw@tr.example.com:443?'));
      expect(essence(single(uri)), essence(n));
    });

    test('shareUri отдаёт source.raw, если узел пришёл ссылкой', () {
      final n = single(vlessReality);
      expect(shareUri(n), vlessReality);
      expect(containsSecrets(n), isTrue);
    });
  });

  group('Модель', () {
    test('toJson / fromJson', () {
      final n = single(hy2);
      final back = ProxyNode.fromJson(
          jsonDecode(jsonEncode(n.toJson())) as Map<String, Object?>);
      expect(back.toJson(), n.toJson());
    });

    test('toRedactedJson скрывает секреты', () {
      final n = single(vlessReality);
      final s = jsonEncode(n.toRedactedJson());
      expect(s, isNot(contains(uuid)));
      expect(s, isNot(contains('6ba85179e30d4fc2')));
    });
  });

  group('Закреплённый сертификат (Xray 26)', () {
    const pcs = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    test('trojan: pcs и vcn сохраняются и попадают обратно в ссылку', () {
      final n = single('trojan://pw@1.2.3.4:443?security=tls&sni=a.example.com'
          '&pcs=$pcs&vcn=a.example.com#T');
      expect(n.security.pinnedCertSha256, pcs);
      expect(n.security.verifyName, 'a.example.com');
      final again = single(nodeToUri(n));
      expect(again.security.pinnedCertSha256, pcs);
      expect(again.security.verifyName, 'a.example.com');
    });
    test('hysteria2: pcs', () {
      final n = single('hysteria2://pw@1.2.3.4:443?sni=a.example.com&pcs=$pcs#H');
      expect(n.security.pinnedCertSha256, pcs);
      expect(nodeToUri(n), contains('pcs=$pcs'));
    });
    test('сохранение в JSON', () {
      final n = single('vless://${'1b9c1b2e-1f4b-4c5e-9d2a-3f4e5d6c7b8a'}@1.2.3.4:443'
          '?security=tls&sni=a.example.com&pcs=$pcs#V');
      final j = ProxyNode.fromJson(n.toJson());
      expect(j.security.pinnedCertSha256, pcs);
    });
  });
}
