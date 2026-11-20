/// Извлечение узлов из конфигов sing-box (JSON), Xray/V2Ray (JSON)
/// и Clash/Mihomo (YAML).
library;

import 'dart:convert';

import 'model.dart';
import 'result.dart';
import 'util.dart';

typedef ExtractResult = ({List<ProxyNode> nodes, List<ParseIssue> issues});

/// Служебные outbound'ы, которые не являются узлами и пропускаются молча.
const _singBoxSkip = {'direct', 'block', 'dns', 'selector', 'urltest'};
const _xraySkip = {'freedom', 'blackhole', 'dns', 'loopback'};

NodeSource _src(SourceType t, Object? fragment, DateTime now) =>
    NodeSource(type: t, raw: jsonEncode(fragment), importedAt: now.toUtc());

String _name(String? tag, String server, int port) =>
    tag ?? (server.contains(':') ? '[$server]:$port' : '$server:$port');

ParseIssue _unsupported(String kind, String type) => ParseIssue(
    ParseErrorCode.unsupportedProtocol, 'Протокол не поддерживается: $type',
    kind: kind);

int? _validPort(Object? v) {
  final p = toInt(v);
  return (p != null && p >= 1 && p <= 65535) ? p : null;
}

// ===========================================================================
// sing-box

bool looksLikeSingBoxOutbound(Map<String, Object?> o) =>
    o['type'] is String && !o.containsKey('protocol');

ExtractResult extractSingBox(List<Object?> outbounds,
    {SourceType sourceType = SourceType.file, DateTime? now}) {
  final ts = now ?? DateTime.now();
  final nodes = <ProxyNode>[];
  final issues = <ParseIssue>[];
  for (var i = 0; i < outbounds.length; i++) {
    final o = asMap(outbounds[i]);
    final type = (str(o['type']) ?? '').toLowerCase();
    if (type.isEmpty || _singBoxSkip.contains(type)) continue;
    try {
      final n = _singBoxNode(o, type, _src(sourceType, o, ts));
      if (n == null) {
        issues.add(_unsupported('sing-box:$type', type).withIndex(i));
      } else {
        nodes.add(n);
      }
    } on ParseException catch (e) {
      issues.add(e.issue.withIndex(i));
    }
  }
  return (nodes: nodes, issues: issues);
}

SecurityConfig _singBoxTls(Object? tlsObj, {bool forceTls = false}) {
  final tls = asMap(tlsObj);
  final enabled = toBool(tls['enabled']) || forceTls;
  if (!enabled) return const SecurityConfig();
  final reality = asMap(tls['reality']);
  final utls = asMap(tls['utls']);
  final isReality = toBool(reality['enabled']);
  return SecurityConfig(
    type: isReality ? 'reality' : 'tls',
    sni: str(tls['server_name']),
    insecure: toBool(tls['insecure']),
    fingerprint: toBool(utls['enabled']) ? str(utls['fingerprint']) : null,
    alpn: asList(tls['alpn']).map((e) => e.toString()).toList(),
    publicKey: str(reality['public_key']),
    shortId: str(reality['short_id']),
  );
}

TransportConfig _singBoxTransport(Object? tObj) {
  final t = asMap(tObj);
  final type = normalizeTransport(str(t['type']));
  final headers = asMap(t['headers']);
  final hostVal = t['host'];
  String? host = hostVal is List
      ? (hostVal.isEmpty ? null : str(hostVal.first))
      : str(hostVal);
  host ??= str(headers['Host']) ?? str(headers['host']);
  return TransportConfig(
    type: type,
    host: host,
    path: str(t['path']),
    serviceName: str(t['service_name']),
  );
}

ProxyNode? _singBoxNode(Map<String, Object?> o, String type, NodeSource src) {
  final kind = 'sing-box:$type';
  final server = str(o['server']);
  final port = _validPort(o['server_port']);
  final tag = str(o['tag']);

  // У hysteria2 вместо server_port может быть только server_ports.
  final ports = asList(o['server_ports']).map((e) => e.toString()).toList();

  if (server == null) {
    throw ParseException(ParseErrorCode.missingField, 'Не указан адрес',
        kind: kind);
  }

  int requirePort() {
    if (port != null) return port;
    if (ports.isNotEmpty) {
      final m = RegExp(r'\d+').firstMatch(ports.first);
      final p = m == null ? null : int.tryParse(m.group(0)!);
      if (p != null) return p;
    }
    throw ParseException(ParseErrorCode.missingField, 'Не указан порт',
        kind: kind);
  }

  String requireStr(String key, String what) {
    final v = str(o[key]);
    if (v == null) {
      throw ParseException(ParseErrorCode.missingField, 'Не указан $what',
          kind: kind);
    }
    return v;
  }

  switch (type) {
    case 'vless':
      final p = requirePort();
      return ProxyNode(
        id: generateId(),
        name: _name(tag, server, p),
        protocol: ProxyProtocol.vless,
        server: server,
        port: p,
        uuid: requireStr('uuid', 'UUID'),
        flow: str(o['flow']),
        transport: _singBoxTransport(o['transport']),
        security: _singBoxTls(o['tls']),
        source: src,
      );
    case 'vmess':
      final p = requirePort();
      return ProxyNode(
        id: generateId(),
        name: _name(tag, server, p),
        protocol: ProxyProtocol.vmess,
        server: server,
        port: p,
        uuid: requireStr('uuid', 'UUID'),
        alterId: toInt(o['alter_id']) ?? 0,
        vmessCipher: str(o['security']) ?? 'auto',
        transport: _singBoxTransport(o['transport']),
        security: _singBoxTls(o['tls']),
        source: src,
      );
    case 'trojan':
      final p = requirePort();
      return ProxyNode(
        id: generateId(),
        name: _name(tag, server, p),
        protocol: ProxyProtocol.trojan,
        server: server,
        port: p,
        password: requireStr('password', 'пароль'),
        transport: _singBoxTransport(o['transport']),
        security: _singBoxTls(o['tls']),
        source: src,
      );
    case 'shadowsocks':
      final p = requirePort();
      return ProxyNode(
        id: generateId(),
        name: _name(tag, server, p),
        protocol: ProxyProtocol.shadowsocks,
        server: server,
        port: p,
        method: requireStr('method', 'метод шифрования').toLowerCase(),
        password: requireStr('password', 'пароль'),
        plugin: str(o['plugin']),
        pluginOpts: str(o['plugin_opts']),
        source: src,
      );
    case 'hysteria2':
      final p = requirePort();
      final obfs = asMap(o['obfs']);
      return ProxyNode(
        id: generateId(),
        name: _name(tag, server, p),
        protocol: ProxyProtocol.hysteria2,
        server: server,
        port: p,
        portRange: ports.isEmpty
            ? null
            : ports.map((e) => e.replaceAll(':', '-')).join(','),
        password: str(o['password']),
        obfs: str(obfs['type']),
        obfsPassword: str(obfs['password']),
        upMbps: toInt(o['up_mbps']),
        downMbps: toInt(o['down_mbps']),
        transport: const TransportConfig(type: 'udp'),
        security: _singBoxTls(o['tls'], forceTls: true),
        source: src,
      );
    case 'tuic':
      final p = requirePort();
      return ProxyNode(
        id: generateId(),
        name: _name(tag, server, p),
        protocol: ProxyProtocol.tuic,
        server: server,
        port: p,
        uuid: requireStr('uuid', 'UUID'),
        password: str(o['password']),
        congestionControl: str(o['congestion_control']) ?? 'bbr',
        udpRelayMode: str(o['udp_relay_mode']),
        transport: const TransportConfig(type: 'udp'),
        security: _singBoxTls(o['tls'], forceTls: true),
        source: src,
      );
    case 'socks':
      final p = requirePort();
      final version = str(o['version']);
      if (version != null && version != '5') return null;
      return ProxyNode(
        id: generateId(),
        name: _name(tag, server, p),
        protocol: ProxyProtocol.socks,
        server: server,
        port: p,
        username: str(o['username']),
        password: str(o['password']),
        source: src,
      );
    case 'http':
      final p = requirePort();
      return ProxyNode(
        id: generateId(),
        name: _name(tag, server, p),
        protocol: ProxyProtocol.http,
        server: server,
        port: p,
        username: str(o['username']),
        password: str(o['password']),
        security: _singBoxTls(o['tls']),
        source: src,
      );
    default:
      return null;
  }
}

// ===========================================================================
// Xray / V2Ray

bool looksLikeXrayOutbound(Map<String, Object?> o) => o['protocol'] is String;

ExtractResult extractXray(List<Object?> outbounds,
    {SourceType sourceType = SourceType.file, DateTime? now}) {
  final ts = now ?? DateTime.now();
  final nodes = <ProxyNode>[];
  final issues = <ParseIssue>[];
  for (var i = 0; i < outbounds.length; i++) {
    final o = asMap(outbounds[i]);
    final proto = (str(o['protocol']) ?? '').toLowerCase();
    if (proto.isEmpty || _xraySkip.contains(proto)) continue;
    try {
      final n = _xrayNode(o, proto, _src(sourceType, o, ts));
      if (n == null) {
        issues.add(_unsupported('xray:$proto', proto).withIndex(i));
      } else {
        nodes.add(n);
      }
    } on ParseException catch (e) {
      issues.add(e.issue.withIndex(i));
    }
  }
  return (nodes: nodes, issues: issues);
}

(TransportConfig, SecurityConfig) _xrayStream(Object? ssObj) {
  final ss = asMap(ssObj);
  final net = normalizeTransport(str(ss['network']));
  Map<String, Object?> settingsFor(List<String> keys) {
    for (final k in keys) {
      final m = asMap(ss[k]);
      if (m.isNotEmpty) return m;
    }
    return const {};
  }

  TransportConfig transport;
  switch (net) {
    case 'ws':
      final ws = settingsFor(['wsSettings']);
      transport = TransportConfig(
        type: 'ws',
        path: str(ws['path']),
        host: str(ws['host']) ?? str(asMap(ws['headers'])['Host']),
      );
    case 'grpc':
      final g = settingsFor(['grpcSettings']);
      transport = TransportConfig(
          type: 'grpc', serviceName: str(g['serviceName']));
    case 'httpupgrade':
      final h = settingsFor(['httpupgradeSettings']);
      transport = TransportConfig(
          type: 'httpupgrade', path: str(h['path']), host: str(h['host']));
    case 'xhttp':
      final x = settingsFor(['xhttpSettings', 'splithttpSettings']);
      transport = TransportConfig(
        type: 'xhttp',
        path: str(x['path']),
        host: str(x['host']),
        mode: str(x['mode']),
      );
    case 'tcp':
      final t = settingsFor(['tcpSettings', 'rawSettings']);
      final header = str(asMap(t['header'])['type']);
      transport = TransportConfig(
          type: 'tcp', headerType: header == 'none' ? null : header);
    default:
      transport = TransportConfig(type: net);
  }

  final sec = (str(ss['security']) ?? 'none').toLowerCase();
  SecurityConfig security;
  if (sec == 'reality') {
    final r = settingsFor(['realitySettings']);
    security = SecurityConfig(
      type: 'reality',
      sni: str(r['serverName']),
      fingerprint: str(r['fingerprint']),
      publicKey: str(r['publicKey']) ?? str(r['password']),
      shortId: str(r['shortId']),
      spiderX: str(r['spiderX']),
    );
  } else if (sec == 'tls' || sec == 'xtls') {
    final t = settingsFor(['tlsSettings', 'xtlsSettings']);
    security = SecurityConfig(
      type: 'tls',
      sni: str(t['serverName']),
      insecure: toBool(t['allowInsecure']),
      fingerprint: str(t['fingerprint']),
      alpn: asList(t['alpn']).map((e) => e.toString()).toList(),
    );
  } else {
    security = const SecurityConfig();
  }
  return (transport, security);
}

ProxyNode? _xrayNode(Map<String, Object?> o, String proto, NodeSource src) {
  final kind = 'xray:$proto';
  final settings = asMap(o['settings']);
  final tag = str(o['tag']);
  final (transport, security) = _xrayStream(o['streamSettings']);

  Never missing(String what) => throw ParseException(
      ParseErrorCode.missingField, 'Не указан $what',
      kind: kind);

  switch (proto) {
    case 'vless':
    case 'vmess':
      // Классический формат: settings.vnext[0].users[0];
      // новый плоский: settings.address/port/id.
      final vnext = asMap(asList(settings['vnext']).firstOrNull);
      final srv = vnext.isNotEmpty ? vnext : settings;
      final user = asMap(asList(srv['users']).firstOrNull);
      final u = user.isNotEmpty ? user : settings;
      final server = str(srv['address']) ?? missing('адрес');
      final port = _validPort(srv['port']) ?? missing('порт');
      final id = str(u['id']) ?? missing('UUID');
      if (proto == 'vless') {
        final enc = str(u['encryption']);
        if (enc != null && enc != 'none') {
          throw ParseException(ParseErrorCode.unsupportedProtocol,
              'Шифрование VLESS «$enc» не поддерживается',
              kind: kind);
        }
      }
      return ProxyNode(
        id: generateId(),
        name: _name(tag, server, port),
        protocol: proto == 'vless' ? ProxyProtocol.vless : ProxyProtocol.vmess,
        server: server,
        port: port,
        uuid: id,
        flow: proto == 'vless' ? str(u['flow']) : null,
        alterId: proto == 'vmess' ? (toInt(u['alterId']) ?? 0) : null,
        vmessCipher: proto == 'vmess' ? (str(u['security']) ?? 'auto') : null,
        transport: transport,
        security: security,
        source: src,
      );
    case 'trojan':
    case 'shadowsocks':
      final s0 = asMap(asList(settings['servers']).firstOrNull);
      final s = s0.isNotEmpty ? s0 : settings;
      final server = str(s['address']) ?? missing('адрес');
      final port = _validPort(s['port']) ?? missing('порт');
      final password = str(s['password']) ?? missing('пароль');
      if (proto == 'trojan') {
        return ProxyNode(
          id: generateId(),
          name: _name(tag, server, port),
          protocol: ProxyProtocol.trojan,
          server: server,
          port: port,
          password: password,
          flow: str(s['flow']),
          transport: transport,
          security: security,
          source: src,
        );
      }
      return ProxyNode(
        id: generateId(),
        name: _name(tag, server, port),
        protocol: ProxyProtocol.shadowsocks,
        server: server,
        port: port,
        method: (str(s['method']) ?? missing('метод шифрования')).toLowerCase(),
        password: password,
        source: src,
      );
    case 'socks':
    case 'http':
      final s0 = asMap(asList(settings['servers']).firstOrNull);
      final s = s0.isNotEmpty ? s0 : settings;
      final server = str(s['address']) ?? missing('адрес');
      final port = _validPort(s['port']) ?? missing('порт');
      final user = asMap(asList(s['users']).firstOrNull);
      return ProxyNode(
        id: generateId(),
        name: _name(tag, server, port),
        protocol: proto == 'socks' ? ProxyProtocol.socks : ProxyProtocol.http,
        server: server,
        port: port,
        username: str(user['user']),
        password: str(user['pass']),
        source: src,
      );
    default:
      return null;
  }
}

// ===========================================================================
// Clash / Mihomo YAML (секция proxies)

ExtractResult extractClash(List<Object?> proxies,
    {SourceType sourceType = SourceType.file, DateTime? now}) {
  final ts = now ?? DateTime.now();
  final nodes = <ProxyNode>[];
  final issues = <ParseIssue>[];
  for (var i = 0; i < proxies.length; i++) {
    final p = asMap(proxies[i]);
    final type = (str(p['type']) ?? '').toLowerCase();
    if (type.isEmpty) {
      issues.add(const ParseIssue(
              ParseErrorCode.malformed, 'У прокси не указан type',
              kind: 'clash')
          .withIndex(i));
      continue;
    }
    try {
      final n = _clashNode(p, type, _src(sourceType, p, ts));
      if (n == null) {
        issues.add(_unsupported('clash:$type', type).withIndex(i));
      } else {
        nodes.add(n);
      }
    } on ParseException catch (e) {
      issues.add(e.issue.withIndex(i));
    }
  }
  return (nodes: nodes, issues: issues);
}

TransportConfig _clashTransport(Map<String, Object?> p) {
  final net = (str(p['network']) ?? 'tcp').toLowerCase();
  switch (net) {
    case 'ws':
      final ws = asMap(p['ws-opts']);
      final headers = asMap(ws['headers']);
      final upgrade = toBool(ws['v2ray-http-upgrade']);
      return TransportConfig(
        type: upgrade ? 'httpupgrade' : 'ws',
        path: str(ws['path']),
        host: str(headers['Host']) ?? str(headers['host']),
      );
    case 'grpc':
      final g = asMap(p['grpc-opts']);
      return TransportConfig(
          type: 'grpc', serviceName: str(g['grpc-service-name']));
    case 'h2':
      final h = asMap(p['h2-opts']);
      final hosts = asList(h['host']);
      return TransportConfig(
        type: 'h2',
        path: str(h['path']),
        host: hosts.isEmpty ? null : str(hosts.first),
      );
    case 'http':
      // В Clash network: http — это HTTP-заголовок поверх TCP, а не h2.
      return const TransportConfig(type: 'tcp', headerType: 'http');
    case 'xhttp':
      final x = asMap(p['xhttp-opts']);
      return TransportConfig(
          type: 'xhttp', path: str(x['path']), host: str(x['host']));
    default:
      return TransportConfig(type: normalizeTransport(net));
  }
}

SecurityConfig _clashTls(Map<String, Object?> p, {bool forceTls = false}) {
  final reality = asMap(p['reality-opts']);
  final tls = toBool(p['tls']) || forceTls;
  if (!tls && reality.isEmpty) return const SecurityConfig();
  return SecurityConfig(
    type: reality.isNotEmpty ? 'reality' : 'tls',
    sni: str(p['servername']) ?? str(p['sni']),
    insecure: toBool(p['skip-cert-verify']),
    fingerprint: str(p['client-fingerprint']),
    alpn: asList(p['alpn']).map((e) => e.toString()).toList(),
    publicKey: str(reality['public-key']),
    shortId: str(reality['short-id']),
  );
}

ProxyNode? _clashNode(Map<String, Object?> p, String type, NodeSource src) {
  final kind = 'clash:$type';
  final name = str(p['name']);

  Never missing(String what) => throw ParseException(
      ParseErrorCode.missingField, 'Не указан $what',
      kind: kind);

  final server = str(p['server']) ?? missing('адрес');
  final portsStr = str(p['ports']);
  final port = _validPort(p['port']) ??
      (portsStr != null
          ? int.tryParse(RegExp(r'\d+').firstMatch(portsStr)?.group(0) ?? '')
          : null) ??
      missing('порт');

  switch (type) {
    case 'vless':
      return ProxyNode(
        id: generateId(),
        name: _name(name, server, port),
        protocol: ProxyProtocol.vless,
        server: server,
        port: port,
        uuid: str(p['uuid']) ?? missing('UUID'),
        flow: str(p['flow']),
        transport: _clashTransport(p),
        security: _clashTls(p),
        source: src,
      );
    case 'vmess':
      return ProxyNode(
        id: generateId(),
        name: _name(name, server, port),
        protocol: ProxyProtocol.vmess,
        server: server,
        port: port,
        uuid: str(p['uuid']) ?? missing('UUID'),
        alterId: toInt(p['alterId']) ?? 0,
        vmessCipher: str(p['cipher']) ?? 'auto',
        transport: _clashTransport(p),
        security: _clashTls(p),
        source: src,
      );
    case 'trojan':
      // У trojan в Clash TLS включён всегда.
      return ProxyNode(
        id: generateId(),
        name: _name(name, server, port),
        protocol: ProxyProtocol.trojan,
        server: server,
        port: port,
        password: str(p['password']) ?? missing('пароль'),
        transport: _clashTransport(p),
        security: _clashTls(p, forceTls: true),
        source: src,
      );
    case 'ss':
      final opts = asMap(p['plugin-opts']);
      return ProxyNode(
        id: generateId(),
        name: _name(name, server, port),
        protocol: ProxyProtocol.shadowsocks,
        server: server,
        port: port,
        method: (str(p['cipher']) ?? missing('метод шифрования')).toLowerCase(),
        password: str(p['password']) ?? missing('пароль'),
        plugin: str(p['plugin']),
        pluginOpts: opts.isEmpty
            ? null
            : opts.entries.map((e) => '${e.key}=${e.value}').join(';'),
        source: src,
      );
    case 'hysteria2':
      final obfs = str(p['obfs']);
      return ProxyNode(
        id: generateId(),
        name: _name(name, server, port),
        protocol: ProxyProtocol.hysteria2,
        server: server,
        port: port,
        portRange: portsStr,
        password: str(p['password']) ?? str(p['auth']),
        obfs: (obfs == null || obfs == 'none') ? null : obfs,
        obfsPassword: str(p['obfs-password']),
        upMbps: parseMbps(p['up']),
        downMbps: parseMbps(p['down']),
        transport: const TransportConfig(type: 'udp'),
        security: _clashTls(p, forceTls: true),
        source: src,
      );
    case 'tuic':
      return ProxyNode(
        id: generateId(),
        name: _name(name, server, port),
        protocol: ProxyProtocol.tuic,
        server: server,
        port: port,
        uuid: str(p['uuid']) ?? missing('UUID'),
        password: str(p['password']),
        congestionControl: str(p['congestion-controller']) ?? 'bbr',
        udpRelayMode: str(p['udp-relay-mode']),
        transport: const TransportConfig(type: 'udp'),
        security: _clashTls(p, forceTls: true),
        source: src,
      );
    case 'socks5':
      return ProxyNode(
        id: generateId(),
        name: _name(name, server, port),
        protocol: ProxyProtocol.socks,
        server: server,
        port: port,
        username: str(p['username']),
        password: str(p['password']),
        security: _clashTls(p),
        source: src,
      );
    case 'http':
      return ProxyNode(
        id: generateId(),
        name: _name(name, server, port),
        protocol: ProxyProtocol.http,
        server: server,
        port: port,
        username: str(p['username']),
        password: str(p['password']),
        security: _clashTls(p),
        source: src,
      );
    default:
      return null;
  }
}
