/// Ключи AmneziaVPN: `vpn://…` и нативный JSON (`containers`).
///
/// Формат ключа: `vpn://` + base64url( qCompress( JSON ) ), где qCompress —
/// 4 байта длины (big-endian) + zlib-поток. Внутри — список контейнеров;
/// у каждого протокольный объект с `last_config` (JSON-строка), в котором
/// для AmneziaWG/WireGuard лежит готовый INI в поле `config`.
library;

import 'dart:convert';
import 'dart:io' show zlib;

import 'config_formats.dart';
import 'model.dart';
import 'result.dart';
import 'util.dart';
import 'wireguard.dart';

/// Декодирует `vpn://…` в JSON. null — если это не ключ Amnezia.
Map<String, Object?>? decodeAmneziaKey(String link) {
  var body = link.trim();
  if (body.toLowerCase().startsWith('vpn://')) body = body.substring(6);
  final bytes = tryDecodeBase64Bytes(body);
  if (bytes == null || bytes.isEmpty) return null;

  // Варианты заголовка: qCompress (4 байта), расширенный заголовок
  // сторонних генераторов (12 байт), «голый» zlib, несжатый JSON.
  final candidates = <List<int> Function()>[
    if (bytes.length > 4) () => zlib.decode(bytes.sublist(4)),
    if (bytes.length > 12) () => zlib.decode(bytes.sublist(12)),
    () => zlib.decode(bytes),
    () => bytes,
  ];
  for (final c in candidates) {
    try {
      final json = jsonDecode(utf8.decode(c()));
      if (json is Map) return asMap(json);
    } catch (_) {
      // следующий вариант
    }
  }
  return null;
}

bool looksLikeAmneziaJson(Map<String, Object?> m) =>
    m.containsKey('containers') ||
    (m.containsKey('api_key') && m.containsKey('config_version'));

/// Контейнеры-сервисы, которые не являются VPN-подключением.
const _serviceContainers = {
  'amnezia-dns',
  'amnezia-sftp',
  'amnezia-tor',
  'amnezia-socks5proxy',
};

ExtractResult extractAmnezia(Map<String, Object?> root,
    {required String raw, SourceType sourceType = SourceType.uri, DateTime? now}) {
  final ts = (now ?? DateTime.now()).toUtc();
  final nodes = <ProxyNode>[];
  final issues = <ParseIssue>[];
  final source = NodeSource(type: sourceType, raw: raw, importedAt: ts);

  // Ключи Amnezia Premium / Free: конфиг выдаёт сервер Amnezia по api_key.
  if (root.containsKey('api_key') ||
      root.containsKey('api_endpoint') ||
      root.containsKey('auth_data')) {
    issues.add(const ParseIssue(
        ParseErrorCode.unsupportedProtocol,
        'Ключ Amnezia Premium/Free получает настройки с серверов Amnezia — '
        'такой ключ не поддерживается. Используйте ключ своего сервера '
        'или файл .conf AmneziaWG',
        kind: 'amnezia:api'));
    return (nodes: nodes, issues: issues);
  }

  final containers = asList(root['containers']);
  if (containers.isEmpty) {
    issues.add(const ParseIssue(
        ParseErrorCode.malformed, 'В ключе Amnezia нет подключений',
        kind: 'amnezia'));
    return (nodes: nodes, issues: issues);
  }

  final dns1 = str(root['dns1']) ?? '1.1.1.1';
  final dns2 = str(root['dns2']) ?? '1.0.0.1';
  final hostName = str(root['hostName']);
  final description = str(root['description']);
  final multi = containers.length > 1;

  for (var i = 0; i < containers.length; i++) {
    final c = asMap(containers[i]);
    final cname = (str(c['container']) ?? '').toLowerCase();
    if (_serviceContainers.contains(cname)) continue;

    String? label;
    Map<String, Object?>? proto;
    var kind = '';
    if (cname.startsWith('amnezia-awg') || c.containsKey('awg')) {
      proto = asMap(c['awg']);
      label = 'AWG';
      kind = 'awg';
    } else if (cname == 'amnezia-wireguard' || c.containsKey('wireguard')) {
      proto = asMap(c['wireguard']);
      label = 'WireGuard';
      kind = 'wireguard';
    } else if (cname == 'amnezia-xray' || c.containsKey('xray')) {
      proto = asMap(c['xray']);
      label = 'XRay';
      kind = 'xray';
    } else if (cname == 'amnezia-ssxray' || c.containsKey('ssxray')) {
      proto = asMap(c['ssxray']);
      label = 'SS';
      kind = 'xray';
    }

    if (proto == null) {
      final what = cname.replaceFirst('amnezia-', '');
      issues.add(ParseIssue(ParseErrorCode.unsupportedProtocol,
              'Протокол не поддерживается: ${what.isEmpty ? 'неизвестный' : what}',
              kind: 'amnezia:$what')
          .withIndex(i));
      continue;
    }

    final baseName = description ?? hostName ?? 'Amnezia';
    final name = multi ? '$baseName ($label)' : baseName;
    final lc = _lastConfig(proto['last_config']);

    try {
      if (kind == 'xray') {
        final cfg = lc['outbounds'] != null
            ? lc
            : asMap(_tryJson(str(lc['config'])));
        final r = extractXray(asList(cfg['outbounds']),
            sourceType: sourceType, now: ts);
        if (r.nodes.isEmpty && r.issues.isEmpty) {
          issues.add(const ParseIssue(
                  ParseErrorCode.missingField, 'Пустая конфигурация XRay',
                  kind: 'amnezia:xray')
              .withIndex(i));
        }
        for (final n in r.nodes) {
          nodes.add(n.copyWith(name: name, source: source));
        }
        issues.addAll(r.issues.map((e) => e.withIndex(i)));
        continue;
      }

      // AmneziaWG / WireGuard
      final host = str(lc['hostName']) ?? hostName;
      final port = toInt(lc['port']) ?? toInt(proto['port']);
      final mtu = toInt(lc['mtu']) ?? toInt(proto['mtu']);
      var conf = str(lc['config']) ?? _buildConf(lc, proto, host, port);
      conf = conf
          .replaceAll(r'$PRIMARY_DNS', dns1)
          .replaceAll(r'$SECONDARY_DNS', dns2);
      final node = parseWgConf(conf,
          source: source,
          name: name,
          fallbackHost: host,
          fallbackPort: port,
          fallbackMtu: mtu);
      nodes.add(node);
    } on ParseException catch (e) {
      issues.add(e.issue.withIndex(i));
    }
  }
  return (nodes: nodes, issues: issues);
}

Map<String, Object?> _lastConfig(Object? v) {
  if (v is Map) return asMap(v);
  if (v is String) return asMap(_tryJson(v));
  return const {};
}

Object? _tryJson(String? s) {
  if (s == null) return null;
  try {
    return jsonDecode(s);
  } on FormatException {
    return null;
  }
}

/// INI из отдельных полей last_config (старые версии клиента).
String _buildConf(Map<String, Object?> lc, Map<String, Object?> proto,
    String? host, int? port) {
  String? f(String k) {
    final v = lc[k] ?? proto[k];
    return v is List ? v.map((e) => e.toString()).join(', ') : str(v);
  }

  final b = StringBuffer('[Interface]\n');
  void kv(String k, String? v) {
    if (v != null) b.writeln('$k = $v');
  }

  kv('PrivateKey', f('client_priv_key'));
  final ip = f('client_ip');
  kv('Address', ip == null ? null : (ip.contains('/') ? ip : '$ip/32'));
  kv('DNS', r'$PRIMARY_DNS, $SECONDARY_DNS');
  for (final k in const [
    'Jc', 'Jmin', 'Jmax', 'S1', 'S2', 'S3', 'S4', //
    'H1', 'H2', 'H3', 'H4', 'I1', 'I2', 'I3', 'I4', 'I5',
  ]) {
    kv(k, f(k));
  }
  b.writeln('[Peer]');
  kv('PublicKey', f('server_pub_key'));
  kv('PresharedKey', f('psk_key'));
  kv('AllowedIPs', f('allowed_ips') ?? '0.0.0.0/0, ::/0');
  if (host != null && port != null) {
    kv('Endpoint', host.contains(':') ? '[$host]:$port' : '$host:$port');
  }
  kv('PersistentKeepalive', f('persistent_keep_alive'));
  return b.toString();
}
