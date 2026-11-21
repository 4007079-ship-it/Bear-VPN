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
  http,

  /// Обычный WireGuard (из .conf или контейнера amnezia-wireguard).
  wireguard,

  /// AmneziaWG — WireGuard с обфускацией (Jc/Jmin/Jmax, S1–S4, H1–H4, I1–I5).
  amneziawg;

  bool get isWireGuardFamily => this == wireguard || this == amneziawg;

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

/// Параметры обфускации AmneziaWG.
///
/// v1.0: Jc, Jmin, Jmax, S1, S2, H1–H4 (числа).
/// v1.5: + I1–I5 (сигнатурные пакеты).
/// v2.0: + S3, S4; H1–H4 могут быть диапазонами `123-456`.
/// Неизвестные ключи (AWG 3.x и новее, например HeaderProtectionKey)
/// сохраняются в [extra] и не теряются при экспорте.
class AwgParams {
  final int? jc;
  final int? jmin;
  final int? jmax;
  final int? s1;
  final int? s2;
  final int? s3;
  final int? s4;

  /// H1–H4: число или диапазон `min-max`.
  final String? h1;
  final String? h2;
  final String? h3;
  final String? h4;

  /// I1–I5: сигнатурные пакеты (`<b 0x…><r 16>…`).
  final String? i1;
  final String? i2;
  final String? i3;
  final String? i4;
  final String? i5;

  /// Прочие ключи секции [Interface] в исходном написании.
  final Map<String, String> extra;

  const AwgParams({
    this.jc,
    this.jmin,
    this.jmax,
    this.s1,
    this.s2,
    this.s3,
    this.s4,
    this.h1,
    this.h2,
    this.h3,
    this.h4,
    this.i1,
    this.i2,
    this.i3,
    this.i4,
    this.i5,
    this.extra = const {},
  });

  List<String?> get headers => [h1, h2, h3, h4];
  List<String?> get signatures => [i1, i2, i3, i4, i5];

  /// Версия протокола по набору параметров: '1.0', '1.5', '2.0' или '3+'.
  String get version {
    if (extra.isNotEmpty) return '3+';
    if (s3 != null || s4 != null || headers.any((h) => h?.contains('-') ?? false)) {
      return '2.0';
    }
    if (signatures.any((i) => i != null && i.isNotEmpty)) return '1.5';
    return '1.0';
  }

  /// Пары ключ/значение в порядке, который принимает amneziawg-go.
  List<MapEntry<String, String>> toIniEntries() => [
        if (jc != null) MapEntry('Jc', '$jc'),
        if (jmin != null) MapEntry('Jmin', '$jmin'),
        if (jmax != null) MapEntry('Jmax', '$jmax'),
        if (s1 != null) MapEntry('S1', '$s1'),
        if (s2 != null) MapEntry('S2', '$s2'),
        if (s3 != null) MapEntry('S3', '$s3'),
        if (s4 != null) MapEntry('S4', '$s4'),
        if (h1 != null) MapEntry('H1', h1!),
        if (h2 != null) MapEntry('H2', h2!),
        if (h3 != null) MapEntry('H3', h3!),
        if (h4 != null) MapEntry('H4', h4!),
        if (i1 != null) MapEntry('I1', i1!),
        if (i2 != null) MapEntry('I2', i2!),
        if (i3 != null) MapEntry('I3', i3!),
        if (i4 != null) MapEntry('I4', i4!),
        if (i5 != null) MapEntry('I5', i5!),
        ...extra.entries,
      ];

  Map<String, Object?> toJson() => _compact({
        'jc': jc,
        'jmin': jmin,
        'jmax': jmax,
        's1': s1,
        's2': s2,
        's3': s3,
        's4': s4,
        'h1': h1,
        'h2': h2,
        'h3': h3,
        'h4': h4,
        'i1': i1,
        'i2': i2,
        'i3': i3,
        'i4': i4,
        'i5': i5,
        'extra': extra.isEmpty ? null : extra,
      });

  factory AwgParams.fromJson(Map<String, Object?> j) {
    int? i(String k) => (j[k] as num?)?.toInt();
    String? s(String k) => j[k] as String?;
    return AwgParams(
      jc: i('jc'),
      jmin: i('jmin'),
      jmax: i('jmax'),
      s1: i('s1'),
      s2: i('s2'),
      s3: i('s3'),
      s4: i('s4'),
      h1: s('h1'),
      h2: s('h2'),
      h3: s('h3'),
      h4: s('h4'),
      i1: s('i1'),
      i2: s('i2'),
      i3: s('i3'),
      i4: s('i4'),
      i5: s('i5'),
      extra: ((j['extra'] as Map<String, Object?>?) ?? const {})
          .map((k, v) => MapEntry(k, v.toString())),
    );
  }
}

/// Параметры WireGuard / AmneziaWG. Адрес сервера и порт — в
/// [ProxyNode.server] / [ProxyNode.port] (из Endpoint).
class WireGuardConfig {
  /// Приватный ключ клиента — секрет.
  final String privateKey;

  /// Публичный ключ сервера (Peer.PublicKey).
  final String peerPublicKey;

  /// PresharedKey — секрет.
  final String? presharedKey;

  /// Адреса интерфейса: `10.8.1.2/32`, `fd00::2/128`.
  final List<String> addresses;
  final List<String> dns;
  final int? mtu;
  final List<String> allowedIps;
  final int? persistentKeepalive;

  /// null — обычный WireGuard.
  final AwgParams? awg;

  const WireGuardConfig({
    required this.privateKey,
    required this.peerPublicKey,
    this.presharedKey,
    this.addresses = const [],
    this.dns = const [],
    this.mtu,
    this.allowedIps = const ['0.0.0.0/0', '::/0'],
    this.persistentKeepalive,
    this.awg,
  });

  Map<String, Object?> toJson() => _compact({
        'private_key': privateKey,
        'peer_public_key': peerPublicKey,
        'preshared_key': presharedKey,
        'addresses': addresses,
        'dns': dns.isEmpty ? null : dns,
        'mtu': mtu,
        'allowed_ips': allowedIps,
        'persistent_keepalive': persistentKeepalive,
        'awg': awg?.toJson(),
      });

  factory WireGuardConfig.fromJson(Map<String, Object?> j) {
    List<String> list(String k) =>
        ((j[k] as List<Object?>?) ?? const []).whereType<String>().toList();
    final awg = j['awg'] as Map<String, Object?>?;
    return WireGuardConfig(
      privateKey: (j['private_key'] as String?) ?? '',
      peerPublicKey: (j['peer_public_key'] as String?) ?? '',
      presharedKey: j['preshared_key'] as String?,
      addresses: list('addresses'),
      dns: list('dns'),
      mtu: (j['mtu'] as num?)?.toInt(),
      allowedIps: list('allowed_ips'),
      persistentKeepalive: (j['persistent_keepalive'] as num?)?.toInt(),
      awg: awg == null ? null : AwgParams.fromJson(awg),
    );
  }
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

  /// WireGuard / AmneziaWG (только для этих протоколов).
  final WireGuardConfig? wireguard;

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
    this.wireguard,
    this.transport = const TransportConfig(),
    this.security = const SecurityConfig(),
    this.tags = const [],
  });

  /// Копия с изменёнными метаданными (имя, теги, источник).
  /// Параметры подключения меняются в редакторе через новый ProxyNode.
  ProxyNode copyWith({String? name, List<String>? tags, NodeSource? source}) =>
      ProxyNode(
        id: id,
        name: name ?? this.name,
        protocol: protocol,
        server: server,
        port: port,
        portRange: portRange,
        uuid: uuid,
        password: password,
        username: username,
        flow: flow,
        alterId: alterId,
        vmessCipher: vmessCipher,
        method: method,
        plugin: plugin,
        pluginOpts: pluginOpts,
        obfs: obfs,
        obfsPassword: obfsPassword,
        upMbps: upMbps,
        downMbps: downMbps,
        congestionControl: congestionControl,
        udpRelayMode: udpRelayMode,
        wireguard: wireguard,
        transport: transport,
        security: security,
        tags: tags ?? this.tags,
        source: source ?? this.source,
      );

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
        wireguard?.privateKey ?? '',
        wireguard?.peerPublicKey ?? '',
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
        'wireguard': wireguard?.toJson(),
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
    final wg = j['wireguard'];
    if (wg is Map<String, Object?>) {
      wg['private_key'] = '***';
      if (wg.containsKey('preshared_key')) wg['preshared_key'] = '***';
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
      wireguard: j['wireguard'] == null
          ? null
          : WireGuardConfig.fromJson(j['wireguard'] as Map<String, Object?>),
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
