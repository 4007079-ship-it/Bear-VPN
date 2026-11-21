/// WireGuard / AmneziaWG: разбор и сборка INI-конфига (.conf).
library;

import 'model.dart';
import 'result.dart';
import 'util.dart';

/// Похоже ли на WireGuard/AmneziaWG .conf.
bool looksLikeWgConf(String text) => _interfaceRe.hasMatch(text);

final _interfaceRe =
    RegExp(r'^\s*\[\s*interface\s*\]\s*$', multiLine: true, caseSensitive: false);

/// Ключи wg-quick, которые клиенту не нужны. PreUp/PostUp — это shell-команды,
/// их нельзя ни выполнять, ни переносить в экспорт.
const _ignoredInterfaceKeys = {
  'listenport',
  'table',
  'preup',
  'postup',
  'predown',
  'postdown',
  'saveconfig',
  'fwmark',
};

const _awgIntKeys = {'jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4'};
const _awgStrKeys = {'h1', 'h2', 'h3', 'h4', 'i1', 'i2', 'i3', 'i4', 'i5'};

/// Разбор .conf. Бросает [ParseException].
///
/// [fallbackHost]/[fallbackPort]/[fallbackMtu] — для конфигов Amnezia,
/// где часть значений лежит рядом с INI, а не в нём.
ProxyNode parseWgConf(
  String text, {
  required NodeSource source,
  String? name,
  String? fallbackHost,
  int? fallbackPort,
  int? fallbackMtu,
}) {
  final iface = <String, String>{};
  final ifaceOrig = <String, String>{}; // исходное написание ключей
  final peer = <String, String>{};
  String? section;
  var peers = 0;
  String? commentName;

  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#') || line.startsWith(';')) {
      // «# Name = …» — так имя кладут некоторые генераторы.
      final m = RegExp(r'^[#;]\s*name\s*=\s*(.+)$', caseSensitive: false)
          .firstMatch(line);
      if (m != null && section == null) commentName = m.group(1)!.trim();
      continue;
    }
    if (line.startsWith('[') && line.endsWith(']')) {
      section = line.substring(1, line.length - 1).trim().toLowerCase();
      if (section == 'peer') peers++;
      continue;
    }
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim();
    final value = line.substring(eq + 1).trim();
    final lk = key.toLowerCase();
    if (section == 'interface') {
      if (_ignoredInterfaceKeys.contains(lk)) continue;
      // Address и DNS могут повторяться — склеиваем.
      if ((lk == 'address' || lk == 'dns') && iface.containsKey(lk)) {
        iface[lk] = '${iface[lk]},$value';
      } else {
        iface[lk] = value;
        ifaceOrig[lk] = key;
      }
    } else if (section == 'peer' && peers == 1) {
      // Берём первый [Peer]; клиентские конфиги с несколькими пирами редки.
      if (lk == 'allowedips' && peer.containsKey(lk)) {
        peer[lk] = '${peer[lk]},$value';
      } else {
        peer[lk] = value;
      }
    }
  }

  const kind = 'wireguard';
  final privateKey = iface['privatekey'];
  if (privateKey == null || privateKey.isEmpty) {
    throw ParseException(
        ParseErrorCode.missingField, 'Не указан PrivateKey', kind: kind);
  }
  if (peers == 0) {
    throw ParseException(
        ParseErrorCode.missingField, 'Нет секции [Peer]', kind: kind);
  }
  final publicKey = peer['publickey'];
  if (publicKey == null || publicKey.isEmpty) {
    throw ParseException(ParseErrorCode.missingField,
        'Не указан PublicKey сервера', kind: kind);
  }

  String? host = fallbackHost;
  int? port = fallbackPort;
  final endpoint = peer['endpoint'];
  if (endpoint != null && endpoint.isNotEmpty) {
    final ep = _parseEndpoint(endpoint);
    if (ep == null) {
      throw ParseException(
          ParseErrorCode.malformed, 'Некорректный Endpoint', kind: kind);
    }
    host = ep.$1;
    port = ep.$2;
  }
  if (host == null || host.isEmpty) {
    throw ParseException(
        ParseErrorCode.missingField, 'Не указан Endpoint', kind: kind);
  }
  if (port == null || port < 1 || port > 65535) {
    throw ParseException(
        ParseErrorCode.missingField, 'Не указан порт в Endpoint', kind: kind);
  }

  int? intKey(String k) {
    final v = iface[k];
    if (v == null || v.isEmpty) return null;
    final n = int.tryParse(v);
    if (n == null) {
      throw ParseException(ParseErrorCode.malformed,
          'Некорректное значение ${ifaceOrig[k] ?? k}: $v',
          kind: 'amneziawg');
    }
    return n;
  }

  const knownInterface = {'privatekey', 'address', 'dns', 'mtu'};
  final extra = <String, String>{
    for (final e in iface.entries)
      if (!knownInterface.contains(e.key) &&
          !_awgIntKeys.contains(e.key) &&
          !_awgStrKeys.contains(e.key))
        (ifaceOrig[e.key] ?? e.key): e.value,
  };
  final hasAwg = iface.keys.any(
          (k) => _awgIntKeys.contains(k) || _awgStrKeys.contains(k)) ||
      extra.isNotEmpty;

  String? s(String k) {
    final v = iface[k];
    return (v == null || v.isEmpty) ? null : v;
  }

  final awg = hasAwg
      ? AwgParams(
          jc: intKey('jc'),
          jmin: intKey('jmin'),
          jmax: intKey('jmax'),
          s1: intKey('s1'),
          s2: intKey('s2'),
          s3: intKey('s3'),
          s4: intKey('s4'),
          h1: s('h1'),
          h2: s('h2'),
          h3: s('h3'),
          h4: s('h4'),
          i1: s('i1'),
          i2: s('i2'),
          i3: s('i3'),
          i4: s('i4'),
          i5: s('i5'),
          extra: extra,
        )
      : null;

  final protocol = hasAwg ? ProxyProtocol.amneziawg : ProxyProtocol.wireguard;
  final address = host.contains(':') ? '[$host]:$port' : '$host:$port';
  return ProxyNode(
    id: generateId(),
    name: name ??
        commentName ??
        '${hasAwg ? 'AmneziaWG' : 'WireGuard'} $address',
    protocol: protocol,
    server: host,
    port: port,
    wireguard: WireGuardConfig(
      privateKey: privateKey,
      peerPublicKey: publicKey,
      presharedKey: peer['presharedkey'],
      addresses: splitCsv(iface['address']),
      dns: splitCsv(iface['dns']),
      mtu: intKey('mtu') ?? fallbackMtu,
      allowedIps: peer['allowedips'] == null
          ? const ['0.0.0.0/0', '::/0']
          : splitCsv(peer['allowedips']),
      persistentKeepalive: int.tryParse(peer['persistentkeepalive'] ?? ''),
      awg: awg,
    ),
    transport: const TransportConfig(type: 'udp'),
    source: source,
  );
}

(String, int)? _parseEndpoint(String ep) {
  final s = ep.trim();
  if (s.startsWith('[')) {
    final close = s.indexOf(']');
    if (close < 0 || close + 1 >= s.length || s[close + 1] != ':') return null;
    final port = int.tryParse(s.substring(close + 2));
    return port == null ? null : (s.substring(1, close), port);
  }
  final colon = s.lastIndexOf(':');
  if (colon <= 0) return null;
  final port = int.tryParse(s.substring(colon + 1));
  return port == null ? null : (s.substring(0, colon), port);
}

/// ProxyNode → .conf для AmneziaWG / WireGuard (экспорт и QR).
String nodeToWgConf(ProxyNode n) {
  final wg = n.wireguard;
  if (wg == null) {
    throw ArgumentError('Узел ${n.protocol.name} — не WireGuard');
  }
  final b = StringBuffer()
    ..writeln('[Interface]')
    ..writeln('PrivateKey = ${wg.privateKey}');
  if (wg.addresses.isNotEmpty) b.writeln('Address = ${wg.addresses.join(', ')}');
  if (wg.dns.isNotEmpty) b.writeln('DNS = ${wg.dns.join(', ')}');
  if (wg.mtu != null) b.writeln('MTU = ${wg.mtu}');
  for (final e in wg.awg?.toIniEntries() ?? const <MapEntry<String, String>>[]) {
    b.writeln('${e.key} = ${e.value}');
  }
  b
    ..writeln()
    ..writeln('[Peer]')
    ..writeln('PublicKey = ${wg.peerPublicKey}');
  if (wg.presharedKey != null) b.writeln('PresharedKey = ${wg.presharedKey}');
  b.writeln('AllowedIPs = ${wg.allowedIps.join(', ')}');
  b.writeln('Endpoint = ${n.address}');
  if (wg.persistentKeepalive != null) {
    b.writeln('PersistentKeepalive = ${wg.persistentKeepalive}');
  }
  return b.toString();
}
