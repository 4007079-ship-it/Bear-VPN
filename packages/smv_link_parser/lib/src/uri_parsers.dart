import 'dart:convert';

import 'model.dart';
import 'result.dart';
import 'util.dart';

/// Схемы, которые разбираются в узлы.
const supportedSchemes = {
  'vless',
  'vmess',
  'hysteria2',
  'hy2',
  'tuic',
  'trojan',
  'ss',
  'socks',
  'socks5',
  'http',
  'vpn', // AmneziaVPN, разбирается в LinkParser (amnezia.dart)
};

/// Известные схемы прокси, которые пока не поддерживаются: для них
/// показываем «Протокол не поддерживается», а не «не распознано».
const knownUnsupportedSchemes = {
  'ssr',
  'wireguard',
  'wg',
  'hysteria',
  'hy',
  'naive+https',
  'naive+quic',
  'anytls',
  'juicity',
  'brook',
  'snell',
  'mieru',
  'ssh',
  'socks4',
  'socks4a',
};

/// Разбор одной прокси-ссылки. Бросает [ParseException].
ProxyNode parseProxyUri(String link,
    {SourceType sourceType = SourceType.uri, DateTime? now}) {
  final trimmed = link.trim();
  final sep = trimmed.indexOf('://');
  final scheme = sep > 0 ? trimmed.substring(0, sep).toLowerCase() : '';
  final source = NodeSource(
      type: sourceType,
      raw: trimmed,
      importedAt: (now ?? DateTime.now()).toUtc());

  if (knownUnsupportedSchemes.contains(scheme)) {
    throw ParseException(ParseErrorCode.unsupportedProtocol,
        'Протокол не поддерживается: $scheme',
        kind: scheme);
  }

  switch (scheme) {
    case 'vless':
      return _parseVless(RawLink.parse(trimmed), source);
    case 'vmess':
      return _parseVmess(trimmed, source);
    case 'hysteria2':
    case 'hy2':
      return _parseHysteria2(RawLink.parse(trimmed), source);
    case 'tuic':
      return _parseTuic(RawLink.parse(trimmed), source);
    case 'trojan':
      return _parseTrojan(RawLink.parse(trimmed), source);
    case 'ss':
      return _parseShadowsocks(trimmed, source);
    case 'socks':
    case 'socks5':
      return _parseSocks(RawLink.parse(trimmed), source);
    case 'http':
      return _parseHttpProxy(RawLink.parse(trimmed), source);
    default:
      throw ParseException(
          ParseErrorCode.unrecognized,
          scheme.isEmpty
              ? 'Ссылка не распознана'
              : 'Неизвестный тип ссылки: $scheme',
          kind: scheme.isEmpty ? null : scheme);
  }
}

// ---------------------------------------------------------------------------
// Общие части

void _requireHost(RawLink l) {
  if (l.host.isEmpty) {
    throw ParseException(ParseErrorCode.missingField, 'Не указан адрес сервера',
        kind: l.scheme);
  }
}

int _requirePort(RawLink l, {int? fallback}) {
  final p = l.port ?? fallback;
  if (p == null) {
    throw ParseException(
        ParseErrorCode.missingField,
        l.portText.isEmpty
            ? 'Не указан порт'
            : 'Некорректный порт: ${l.portText}',
        kind: l.scheme);
  }
  if (p < 1 || p > 65535) {
    throw ParseException(ParseErrorCode.malformed, 'Порт вне диапазона: $p',
        kind: l.scheme);
  }
  return p;
}

String _requireUserInfo(RawLink l, String what) {
  final u = l.userInfo;
  if (u == null || u.isEmpty) {
    throw ParseException(ParseErrorCode.missingField, 'Не указан $what',
        kind: l.scheme);
  }
  return pctDecode(u);
}

String _defaultName(String server, int port) =>
    server.contains(':') ? '[$server]:$port' : '$server:$port';

/// Транспорт и TLS/Reality из параметров в стиле Xray share-link
/// (общие для vless, trojan и vmess в URI-форме).
(TransportConfig, SecurityConfig) _streamFromQuery(RawLink l,
    {required String defaultSecurity}) {
  final type = normalizeTransport(l.qAny(['type', 'network', 'net']));
  final transport = TransportConfig(
    type: type,
    host: l.q('host'),
    path: type == 'grpc' ? null : l.q('path'),
    serviceName: l.qAny(['servicename', 'service_name']) ??
        (type == 'grpc' ? l.q('path') : null),
    mode: l.q('mode'),
    headerType: () {
      final h = l.q('headertype');
      return (h == null || h == 'none') ? null : h;
    }(),
  );

  var secType = (l.q('security') ?? defaultSecurity).toLowerCase();
  if (secType == 'xtls') secType = 'tls';
  if (secType != 'tls' && secType != 'reality') secType = 'none';

  final security = SecurityConfig(
    type: secType,
    sni: l.qAny(['sni', 'peer', 'servername']),
    insecure: l.qBool(['allowinsecure', 'insecure', 'skip-cert-verify']),
    fingerprint: l.qAny(['fp', 'fingerprint']),
    alpn: splitCsv(l.q('alpn')),
    publicKey: l.qAny(['pbk', 'publickey', 'public-key']),
    shortId: l.qAny(['sid', 'shortid', 'short-id']),
    spiderX: l.qAny(['spx', 'spiderx']),
  );
  return (transport, security);
}

// ---------------------------------------------------------------------------
// VLESS: vless://uuid@host:port?params#name

ProxyNode _parseVless(RawLink l, NodeSource source) {
  final uuid = _requireUserInfo(l, 'UUID');
  _requireHost(l);
  final port = _requirePort(l);
  final enc = l.q('encryption');
  if (enc != null && enc != 'none') {
    throw ParseException(ParseErrorCode.unsupportedProtocol,
        'Шифрование VLESS «$enc» не поддерживается',
        kind: 'vless');
  }
  final (transport, security) = _streamFromQuery(l, defaultSecurity: 'none');
  return ProxyNode(
    id: generateId(),
    name: l.name ?? _defaultName(l.host, port),
    protocol: ProxyProtocol.vless,
    server: l.host,
    port: port,
    uuid: uuid,
    flow: l.q('flow'),
    transport: transport,
    security: security,
    source: source,
  );
}

// ---------------------------------------------------------------------------
// VMess: vmess://BASE64(JSON) (формат v2rayN) или vmess://uuid@host:port?…

ProxyNode _parseVmess(String link, NodeSource source) {
  final body = link.substring('vmess://'.length);
  final hash = body.indexOf('#');
  final b64 = hash >= 0 ? body.substring(0, hash) : body;
  final decoded = tryDecodeBase64(b64);
  if (decoded != null && decoded.trimLeft().startsWith('{')) {
    final Object? json;
    try {
      json = jsonDecode(decoded);
    } on FormatException {
      throw ParseException(
          ParseErrorCode.malformed, 'Повреждённая ссылка VMess',
          kind: 'vmess');
    }
    final j = asMap(json);
    final server = str(j['add']);
    final port = toInt(j['port']);
    final id = str(j['id']);
    if (server == null) {
      throw ParseException(
          ParseErrorCode.missingField, 'Не указан адрес сервера',
          kind: 'vmess');
    }
    if (port == null || port < 1 || port > 65535) {
      throw ParseException(ParseErrorCode.missingField, 'Некорректный порт',
          kind: 'vmess');
    }
    if (id == null) {
      throw ParseException(ParseErrorCode.missingField, 'Не указан UUID',
          kind: 'vmess');
    }
    final net = normalizeTransport(str(j['net']));
    final headerType = str(j['type']);
    final tls = (str(j['tls']) ?? '').toLowerCase();
    final fragmentName =
        hash >= 0 ? pctDecode(body.substring(hash + 1)).trim() : '';
    return ProxyNode(
      id: generateId(),
      name: str(j['ps']) ??
          (fragmentName.isNotEmpty ? fragmentName : _defaultName(server, port)),
      protocol: ProxyProtocol.vmess,
      server: server,
      port: port,
      uuid: id,
      alterId: toInt(j['aid']) ?? 0,
      vmessCipher: str(j['scy']) ?? 'auto',
      transport: TransportConfig(
        type: net,
        host: str(j['host']),
        // У gRPC в формате v2rayN имя сервиса передаётся в поле path.
        path: net == 'grpc' ? null : str(j['path']),
        serviceName: net == 'grpc' ? str(j['path']) : null,
        headerType:
            (headerType == null || headerType == 'none') ? null : headerType,
      ),
      security: SecurityConfig(
        type: (tls == 'tls' || tls == 'reality') ? tls : 'none',
        sni: str(j['sni']),
        fingerprint: str(j['fp']),
        alpn: splitCsv(str(j['alpn'])),
        insecure: toBool(j['allowInsecure']) || toBool(j['insecure']),
        publicKey: str(j['pbk']),
        shortId: str(j['sid']),
      ),
      source: source,
    );
  }

  // URI-форма (Xray share-link standard).
  final l = RawLink.parse(link);
  if (l.userInfo == null) {
    throw ParseException(ParseErrorCode.malformed, 'Повреждённая ссылка VMess',
        kind: 'vmess');
  }
  final uuid = _requireUserInfo(l, 'UUID');
  _requireHost(l);
  final port = _requirePort(l);
  final (transport, security) = _streamFromQuery(l, defaultSecurity: 'none');
  return ProxyNode(
    id: generateId(),
    name: l.name ?? _defaultName(l.host, port),
    protocol: ProxyProtocol.vmess,
    server: l.host,
    port: port,
    uuid: uuid,
    alterId: 0,
    vmessCipher: l.q('encryption') ?? 'auto',
    transport: transport,
    security: security,
    source: source,
  );
}

// ---------------------------------------------------------------------------
// Hysteria2: hysteria2://auth@host:port[,ports]/?sni=&insecure=&obfs=…#name

final _portRangeRe = RegExp(r'^\d+(-\d+)?(,\d+(-\d+)?)*$');

ProxyNode _parseHysteria2(RawLink l, NodeSource source) {
  _requireHost(l);
  int port;
  String? portRange = l.qAny(['mport', 'ports']);
  final direct = l.port;
  if (direct != null) {
    port = _requirePort(l);
  } else if (_portRangeRe.hasMatch(l.portText)) {
    // Port hopping: «443,20000-30000» или «20000-30000».
    portRange = l.portText;
    port = int.parse(RegExp(r'\d+').firstMatch(l.portText)!.group(0)!);
  } else if (l.portText.isEmpty) {
    port = 443;
  } else {
    port = _requirePort(l);
  }
  if (port < 1 || port > 65535) {
    throw ParseException(ParseErrorCode.malformed, 'Порт вне диапазона: $port',
        kind: 'hysteria2');
  }

  final auth = l.userInfo == null ? l.q('auth') : pctDecode(l.userInfo!);
  final obfs = l.q('obfs');
  return ProxyNode(
    id: generateId(),
    name: l.name ?? _defaultName(l.host, port),
    protocol: ProxyProtocol.hysteria2,
    server: l.host,
    port: port,
    portRange: portRange,
    password: auth,
    obfs: (obfs == null || obfs == 'none') ? null : obfs,
    obfsPassword: l.qAny(['obfs-password', 'obfs_password', 'obfspassword']),
    upMbps: parseMbps(l.q('up')),
    downMbps: parseMbps(l.q('down')),
    security: SecurityConfig(
      type: 'tls',
      sni: l.qAny(['sni', 'peer']),
      insecure: l.qBool(['insecure', 'allowinsecure']),
      alpn: splitCsv(l.q('alpn')),
    ),
    transport: const TransportConfig(type: 'udp'),
    source: source,
  );
}

// ---------------------------------------------------------------------------
// TUIC v5: tuic://uuid:password@host:port?congestion_control=&alpn=&sni=#name

ProxyNode _parseTuic(RawLink l, NodeSource source) {
  final info = _requireUserInfo(l, 'UUID и пароль');
  _requireHost(l);
  final port = _requirePort(l);
  final colon = info.indexOf(':');
  final uuid = colon >= 0 ? info.substring(0, colon) : info;
  final password = colon >= 0 ? info.substring(colon + 1) : l.q('password');
  return ProxyNode(
    id: generateId(),
    name: l.name ?? _defaultName(l.host, port),
    protocol: ProxyProtocol.tuic,
    server: l.host,
    port: port,
    uuid: uuid,
    password: password,
    congestionControl:
        l.qAny(['congestion_control', 'congestion-control', 'cc']) ?? 'bbr',
    udpRelayMode: l.qAny(['udp_relay_mode', 'udp-relay-mode']),
    security: SecurityConfig(
      type: 'tls',
      sni: l.qAny(['sni', 'peer']),
      insecure: l.qBool(['allow_insecure', 'allowinsecure', 'insecure']),
      alpn: l.q('alpn') == null ? const ['h3'] : splitCsv(l.q('alpn')),
    ),
    transport: const TransportConfig(type: 'udp'),
    source: source,
  );
}

// ---------------------------------------------------------------------------
// Trojan: trojan://password@host:port?security=&sni=&type=…#name

ProxyNode _parseTrojan(RawLink l, NodeSource source) {
  final password = _requireUserInfo(l, 'пароль');
  _requireHost(l);
  final port = _requirePort(l, fallback: l.portText.isEmpty ? 443 : null);
  final (transport, security) = _streamFromQuery(l, defaultSecurity: 'tls');
  return ProxyNode(
    id: generateId(),
    name: l.name ?? _defaultName(l.host, port),
    protocol: ProxyProtocol.trojan,
    server: l.host,
    port: port,
    password: password,
    flow: l.q('flow'),
    transport: transport,
    security: security,
    source: source,
  );
}

// ---------------------------------------------------------------------------
// Shadowsocks:
//   SIP002:  ss://BASE64URL(method:password)@host:port/?plugin=…#name
//            ss://method:password@host:port#name (2022-шифры, percent-encoded)
//   Legacy:  ss://BASE64(method:password@host:port)#name

ProxyNode _parseShadowsocks(String link, NodeSource source) {
  final l = RawLink.parse(link);
  if (l.userInfo == null) {
    // Legacy: всё до '?'/'#' — base64(method:password@host:port).
    final body = l.body.endsWith('/')
        ? l.body.substring(0, l.body.length - 1)
        : l.body;
    final decoded = tryDecodeBase64(body);
    if (decoded == null || !decoded.contains('@')) {
      throw ParseException(
          ParseErrorCode.malformed, 'Повреждённая ссылка Shadowsocks',
          kind: 'ss');
    }
    final at = decoded.lastIndexOf('@');
    // Адрес берём из декодированной части, имя и параметры — из исходной.
    final addr = RawLink.parse('ss://x@${decoded.substring(at + 1)}');
    return _ssFromParts(l, decoded.substring(0, at), source, addr: addr);
  }

  final rawInfo = l.userInfo!;
  final plain = pctDecode(rawInfo);
  String creds;
  if (plain.contains(':')) {
    creds = plain;
  } else {
    final decoded = tryDecodeBase64(plain);
    if (decoded == null || !decoded.contains(':')) {
      throw ParseException(ParseErrorCode.malformed,
          'Не удалось прочитать метод и пароль Shadowsocks',
          kind: 'ss');
    }
    creds = decoded;
  }
  return _ssFromParts(l, creds, source);
}

ProxyNode _ssFromParts(RawLink l, String creds, NodeSource source,
    {RawLink? addr}) {
  final colon = creds.indexOf(':');
  if (colon <= 0) {
    throw ParseException(
        ParseErrorCode.missingField, 'Не указан метод шифрования',
        kind: 'ss');
  }
  final method = creds.substring(0, colon).toLowerCase();
  final password = creds.substring(colon + 1);
  final a = addr ?? l;
  _requireHost(a);
  final port = _requirePort(a);
  final server = a.host;

  String? plugin;
  String? pluginOpts;
  final p = l.q('plugin');
  if (p != null) {
    final semi = p.indexOf(';');
    plugin = semi >= 0 ? p.substring(0, semi) : p;
    pluginOpts = semi >= 0 ? p.substring(semi + 1) : null;
  }
  return ProxyNode(
    id: generateId(),
    name: l.name ?? _defaultName(server, port),
    protocol: ProxyProtocol.shadowsocks,
    server: server,
    port: port,
    method: method,
    password: password,
    plugin: plugin,
    pluginOpts: pluginOpts,
    transport: const TransportConfig(type: 'tcp'),
    source: source,
  );
}

// ---------------------------------------------------------------------------
// SOCKS5 / HTTP: socks://[user:pass|BASE64(user:pass)]@host:port#name

(String?, String?) _userPass(RawLink l, {bool allowBase64 = false}) {
  final info = l.userInfo;
  if (info == null || info.isEmpty) return (null, null);
  var plain = pctDecode(info);
  if (!plain.contains(':') && allowBase64) {
    final d = tryDecodeBase64(plain);
    if (d != null && d.contains(':')) plain = d;
  }
  final c = plain.indexOf(':');
  return c >= 0
      ? (plain.substring(0, c), plain.substring(c + 1))
      : (plain, null);
}

ProxyNode _parseSocks(RawLink l, NodeSource source) {
  _requireHost(l);
  final port = _requirePort(l, fallback: l.portText.isEmpty ? 1080 : null);
  final (user, pass) = _userPass(l, allowBase64: true);
  return ProxyNode(
    id: generateId(),
    name: l.name ?? _defaultName(l.host, port),
    protocol: ProxyProtocol.socks,
    server: l.host,
    port: port,
    username: user,
    password: pass,
    source: source,
  );
}

ProxyNode _parseHttpProxy(RawLink l, NodeSource source) {
  _requireHost(l);
  final port = _requirePort(l, fallback: l.portText.isEmpty ? 8080 : null);
  final (user, pass) = _userPass(l);
  return ProxyNode(
    id: generateId(),
    name: l.name ?? _defaultName(l.host, port),
    protocol: ProxyProtocol.http,
    server: l.host,
    port: port,
    username: user,
    password: pass,
    source: source,
  );
}
