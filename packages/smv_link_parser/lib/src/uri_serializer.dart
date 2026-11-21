import 'dart:convert';

import 'model.dart';
import 'util.dart';
import 'wireguard.dart';

/// ProxyNode → ссылка для «Поделиться / QR» (для WireGuard/AmneziaWG —
/// текст .conf).
///
/// Формат совместим с v2rayN, Hiddify, Streisand и sing-box-клиентами.
/// Нужен, потому что `source.raw` есть не всегда в виде ссылки (узлы из
/// JSON/YAML) и устаревает после правки узла в редакторе.
String nodeToUri(ProxyNode n) {
  switch (n.protocol) {
    case ProxyProtocol.vless:
      return _build('vless', _enc(n.uuid ?? ''), n,
          {'encryption': 'none', 'flow': n.flow, ..._stream(n)});
    case ProxyProtocol.trojan:
      return _build('trojan', _enc(n.password ?? ''), n,
          {'flow': n.flow, ..._stream(n)});
    case ProxyProtocol.vmess:
      return _vmess(n);
    case ProxyProtocol.hysteria2:
      final s = n.security;
      return _build(
        'hysteria2',
        _enc(n.password ?? ''),
        n,
        {
          'sni': s.sni,
          'insecure': s.insecure ? '1' : null,
          'alpn': s.alpn.isEmpty ? null : s.alpn.join(','),
          'obfs': n.obfs,
          'obfs-password': n.obfsPassword,
          'mport': n.portRange,
          'up': n.upMbps?.toString(),
          'down': n.downMbps?.toString(),
        },
        pathSlash: true,
      );
    case ProxyProtocol.tuic:
      final s = n.security;
      return _build(
        'tuic',
        '${_enc(n.uuid ?? '')}:${_enc(n.password ?? '')}',
        n,
        {
          'congestion_control': n.congestionControl,
          'udp_relay_mode': n.udpRelayMode,
          'alpn': s.alpn.isEmpty ? null : s.alpn.join(','),
          'sni': s.sni,
          'allow_insecure': s.insecure ? '1' : null,
        },
      );
    case ProxyProtocol.shadowsocks:
      final method = n.method ?? '';
      final pass = n.password ?? '';
      // SIP002: для 2022-шифров — percent-encoded открытый текст,
      // для остальных — base64url(method:password).
      final userInfo = method.startsWith('2022-')
          ? '${_enc(method)}:${_enc(pass)}'
          : encodeBase64Url('$method:$pass');
      final plugin = n.plugin == null
          ? null
          : (n.pluginOpts == null ? n.plugin : '${n.plugin};${n.pluginOpts}');
      return _build('ss', userInfo, n, {'plugin': plugin},
          pathSlash: plugin != null);
    case ProxyProtocol.socks:
    case ProxyProtocol.http:
      final scheme = n.protocol == ProxyProtocol.socks ? 'socks' : 'http';
      final user = n.username;
      final info = user == null
          ? null
          : (n.password == null
              ? _enc(user)
              : '${_enc(user)}:${_enc(n.password!)}');
      return _build(scheme, info, n, const {});
    case ProxyProtocol.wireguard:
    case ProxyProtocol.amneziawg:
      // У WireGuard/AmneziaWG нет общепринятой ссылки: QR-код содержит
      // текст .conf — его читают AmneziaWG, WireGuard и AmneziaVPN.
      return nodeToWgConf(n);
  }
}

Map<String, String?> _stream(ProxyNode n) {
  final t = n.transport;
  final s = n.security;
  return {
    'type': t.type,
    'headerType': t.headerType,
    'host': t.host,
    'path': t.type == 'grpc' ? null : t.path,
    'serviceName': t.serviceName,
    'mode': t.mode,
    'security': s.type,
    'sni': s.sni,
    'fp': s.fingerprint,
    'alpn': s.alpn.isEmpty ? null : s.alpn.join(','),
    'allowInsecure': s.insecure ? '1' : null,
    'pbk': s.publicKey,
    'sid': s.shortId,
    'spx': s.spiderX,
  };
}

String _vmess(ProxyNode n) {
  final t = n.transport;
  final s = n.security;
  final j = <String, Object?>{
    'v': '2',
    'ps': n.name,
    'add': n.server,
    'port': n.port.toString(),
    'id': n.uuid ?? '',
    'aid': (n.alterId ?? 0).toString(),
    'scy': n.vmessCipher ?? 'auto',
    'net': t.type,
    'type': t.headerType ?? 'none',
    'host': t.host ?? '',
    'path': (t.type == 'grpc' ? t.serviceName : t.path) ?? '',
    'tls': s.type == 'none' ? '' : s.type,
    'sni': s.sni ?? '',
    'alpn': s.alpn.join(','),
    'fp': s.fingerprint ?? '',
    if (s.insecure) 'allowInsecure': '1',
    if (s.publicKey != null) 'pbk': s.publicKey,
    if (s.shortId != null) 'sid': s.shortId,
  };
  return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
}

String _build(
  String scheme,
  String? userInfo,
  ProxyNode n,
  Map<String, String?> params, {
  bool pathSlash = false,
}) {
  final host = n.server.contains(':') ? '[${n.server}]' : n.server;
  final q = params.entries
      .where((e) => e.value != null && e.value!.isNotEmpty)
      .map((e) => '${e.key}=${_enc(e.value!)}')
      .join('&');
  final sb = StringBuffer('$scheme://');
  if (userInfo != null && userInfo.isNotEmpty) sb.write('$userInfo@');
  sb.write('$host:${n.port}');
  if (q.isNotEmpty) {
    if (pathSlash) sb.write('/');
    sb.write('?$q');
  }
  if (n.name.isNotEmpty) sb.write('#${_enc(n.name)}');
  return sb.toString();
}

String _enc(String s) => Uri.encodeComponent(s);

/// Ссылка для QR. Если у узла есть исходная ссылка и узел не менялся
/// ([preferRaw]), отдаём её как есть — так точнее сохраняются параметры,
/// которые модель не хранит. Иначе — сериализация из модели.
String shareUri(ProxyNode n, {bool preferRaw = true}) {
  final raw = n.source.raw.trim();
  final isSingleLink = raw.contains('://') &&
      !raw.contains('\n') &&
      !raw.startsWith('{') &&
      !raw.startsWith('[');
  if (preferRaw && isSingleLink) return raw;
  return nodeToUri(n);
}

/// Есть ли в ссылке секреты — для предупреждения «QR содержит ключи доступа».
bool containsSecrets(ProxyNode n) =>
    (n.uuid ?? '').isNotEmpty ||
    (n.password ?? '').isNotEmpty ||
    (n.wireguard?.privateKey ?? '').isNotEmpty;
