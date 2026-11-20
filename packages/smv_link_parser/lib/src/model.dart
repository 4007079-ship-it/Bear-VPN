/// Модель узла SMV.ConfigModel (v0.1), см. docs/node-import.md, п. 5.
library;

enum ProxyProtocol {
  vless,
  vmess,
  hysteria2,
  tuic,
  trojan,
  shadowsocks,
  socks,
  http;

  static ProxyProtocol? fromName(String? name) {
    for (final p in values) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// Откуда пришёл узел.
enum SourceType {
  uri,
  qr,
  file,
  subscription;

  static SourceType fromName(String? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => SourceType.uri);
}

/// Транспорт поверх TCP/UDP.
///
/// [type]: tcp, ws, grpc, httpupgrade, xhttp (поддерживаемые);
/// h2, quic, kcp и прочие сохраняются как есть, но валидатор помечает их
/// как неподдерживаемые.
class TransportConfig {
  final String type;
  final String? host;
  final String? path;
  final String? serviceName;

  /// Режим xhttp (auto, packet-up, stream-up, stream-one).
  final String? mode;

  /// Тип заголовка для tcp (например, `http`), если указан в ссылке.
  final String? headerType;

  const TransportConfig({
    this.type = 'tcp',
    this.host,
    this.path,
    this.serviceName,
    this.mode,
    this.headerType,
  });

  Map<String, Object?> toJson() => _compact({
        'type': type,
        'host': host,
        'path': path,
        'service_name': serviceName,
        'mode': mode,
        'header_type': headerType,
      });

  factory TransportConfig.fromJson(Map<String, Object?> j) => TransportConfig(
        type: (j['type'] as String?) ?? 'tcp',
        host: j['host'] as String?,
        path: j['path'] as String?,
        serviceName: j['service_name'] as String?,
        mode: j['mode'] as String?,
        headerType: j['header_type'] as String?,
      );
}

/// Шифрование канала: none, tls или reality.
class SecurityConfig {
  final String type;
  final String? sni;
  final bool insecure;
  final String? fingerprint;
  final List<String> alpn;

  // Reality
  final String? publicKey;
  final String? shortId;
  final String? spiderX;

  const SecurityConfig({
    this.type = 'none',
    this.sni,
    this.insecure = false,
    this.fingerprint,
    this.alpn = const [],
    this.publicKey,
    this.shortId,
    this.spiderX,
  });

  bool get isTls => type == 'tls' || type == 'reality';
  bool get isReality => type == 'reality';

  Map<String, Object?> toJson() => _compact({
        'type': type,
        'sni': sni,
        'insecure': insecure ? true : null,
        'fingerprint': fingerprint,
        'alpn': alpn.isEmpty ? null : alpn,
        'public_key': publicKey,
        'short_id': shortId,
        'spider_x': spiderX,
      });

  factory SecurityConfig.fromJson(Map<String, Object?> j) => SecurityConfig(
        type: (j['type'] as String?) ?? 'none',
        sni: j['sni'] as String?,
        insecure: j['insecure'] == true,
        fingerprint: j['fingerprint'] as String?,
        alpn: ((j['alpn'] as List<Object?>?) ?? const [])
            .whereType<String>()
            .toList(),
        publicKey: j['public_key'] as String?,
        shortId: j['short_id'] as String?,
        spiderX: j['spider_x'] as String?,
      );
}

class NodeSource {
  final SourceType type;

  /// Исходная строка (ссылка, фрагмент JSON/YAML). Содержит секреты —
  /// хранить только в защищённом хранилище и не логировать.
  final String raw;
  final DateTime importedAt;

  const NodeSource({
    required this.type,
    required this.raw,
    required this.importedAt,
  });

  Map<String, Object?> toJson() => {
        'type': type.name,
        'raw': raw,
        'imported_at': importedAt.toUtc().toIso8601String(),
      };

  factory NodeSource.fromJson(Map<String, Object?> j) => NodeSource(
        type: SourceType.fromName(j['type'] as String?),
        raw: (j['raw'] as String?) ?? '',
        importedAt:
            DateTime.tryParse((j['imported_at'] as String?) ?? '')?.toUtc() ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
}

/// Узел (сервер) в списке Servers.
class ProxyNode {
  final String id;
  final String name;
  final ProxyProtocol protocol;
  final String server;
  final int port;

  /// Диапазон портов Hysteria2 (port hopping), например `443,20000-30000`.
  final String? portRange;

  // Учётные данные (секреты — не показывать в списке узлов).
  final String? uuid;
  final String? password;
  final String? username;

  // VLESS / VMess
  final String? flow;
  final int? alterId;

  /// Шифр VMess (auto, aes-128-gcm, chacha20-poly1305, none, zero).
  final String? vmessCipher;

  // Shadowsocks
  final String? method;
  final String? plugin;
  final String? pluginOpts;

  // Hysteria2
  final String? obfs;
  final String? obfsPassword;
  final int? upMbps;
  final int? downMbps;

  // TUIC
  final String? congestionControl;
  final String? udpRelayMode;

  final TransportConfig transport;
  final SecurityConfig security;
  final List<String> tags;
  final NodeSource source;

  const ProxyNode({
    required this.id,
    required this.name,
    required this.protocol,
    required this.server,
    required this.port,
    required this.source,
    this.portRange,
    this.uuid,
    this.password,
    this.username,
    this.flow,
    this.alterId,
    this.vmessCipher,
    this.method,
    this.plugin,
    this.pluginOpts,
    this.obfs,
    this.obfsPassword,
    this.upMbps,
    this.downMbps,
    this.congestionControl,
    this.udpRelayMode,
    this.transport = const TransportConfig(),
    this.security = const SecurityConfig(),
    this.tags = const [],
  });

  /// Адрес для отображения: `host:port`, IPv6 — в квадратных скобках.
  String get address =>
      server.contains(':') ? '[$server]:$port' : '$server:$port';

  /// Ключ для поиска дубликатов: одинаковые протокол, адрес и учётные
  /// данные считаются одним узлом независимо от имени.
  String get dedupKey => [
        protocol.name,
        server.toLowerCase(),
        port,
        uuid ?? '',
        password ?? '',
        username ?? '',
        method ?? '',
      ].join('|');

  Map<String, Object?> toJson() => _compact({
        'id': id,
        'name': name,
        'protocol': protocol.name,
        'server': server,
        'port': port,
        'port_range': portRange,
        'uuid': uuid,
        'password': password,
        'username': username,
        'flow': flow,
        'alter_id': alterId,
        'vmess_cipher': vmessCipher,
        'method': method,
        'plugin': plugin,
        'plugin_opts': pluginOpts,
        'obfs': obfs,
        'obfs_password': obfsPassword,
        'up_mbps': upMbps,
        'down_mbps': downMbps,
        'congestion_control': congestionControl,
        'udp_relay_mode': udpRelayMode,
        'transport': transport.toJson(),
        'security': security.toJson(),
        'tags': tags,
        'source': source.toJson(),
      });

  /// Версия без секретов — для логов и отладки.
  Map<String, Object?> toRedactedJson() {
    final j = toJson();
    for (final k in const ['uuid', 'password', 'obfs_password']) {
      if (j.containsKey(k)) j[k] = '***';
    }
    final sec = j['security'];
    if (sec is Map<String, Object?> && sec.containsKey('short_id')) {
      sec['short_id'] = '***';
    }
    j.remove('source');
    return j;
  }

  factory ProxyNode.fromJson(Map<String, Object?> j) {
    final protocol = ProxyProtocol.fromName(j['protocol'] as String?);
    if (protocol == null) {
      throw FormatException('Unknown protocol: ${j['protocol']}');
    }
    return ProxyNode(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? '',
      protocol: protocol,
      server: j['server'] as String,
      port: (j['port'] as num).toInt(),
      portRange: j['port_range'] as String?,
      uuid: j['uuid'] as String?,
      password: j['password'] as String?,
      username: j['username'] as String?,
      flow: j['flow'] as String?,
      alterId: (j['alter_id'] as num?)?.toInt(),
      vmessCipher: j['vmess_cipher'] as String?,
      method: j['method'] as String?,
      plugin: j['plugin'] as String?,
      pluginOpts: j['plugin_opts'] as String?,
      obfs: j['obfs'] as String?,
      obfsPassword: j['obfs_password'] as String?,
      upMbps: (j['up_mbps'] as num?)?.toInt(),
      downMbps: (j['down_mbps'] as num?)?.toInt(),
      congestionControl: j['congestion_control'] as String?,
      udpRelayMode: j['udp_relay_mode'] as String?,
      transport: TransportConfig.fromJson(
          (j['transport'] as Map<String, Object?>?) ?? const {}),
      security: SecurityConfig.fromJson(
          (j['security'] as Map<String, Object?>?) ?? const {}),
      tags: ((j['tags'] as List<Object?>?) ?? const [])
          .whereType<String>()
          .toList(),
      source: NodeSource.fromJson(
          (j['source'] as Map<String, Object?>?) ?? const {}),
    );
  }
}

Map<String, Object?> _compact(Map<String, Object?> m) =>
    Map.fromEntries(m.entries.where((e) => e.value != null));
