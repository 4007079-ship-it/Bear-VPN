import 'dart:convert';

import 'package:smv_link_parser/smv_link_parser.dart';

/// Способ распределения трафика между несколькими серверами.
enum BalanceStrategy {
  /// Всё через сервер с наименьшей задержкой, остальные — запасные.
  fastest('leastPing', 'Самый быстрый'),

  /// Соединения по очереди раскладываются по всем живым серверам.
  spread('roundRobin', 'Поровну');

  final String xray;
  final String label;
  const BalanceStrategy(this.xray, this.label);
}

/// Каким IP подключаться к самому серверу (если у него есть и IPv4, и IPv6).
enum ServerIp {
  auto(null, 'Авто'),
  ipv4('UseIPv4', 'IPv4'),
  ipv6('UseIPv6v4', 'IPv6');

  /// Значение `sockopt.domainStrategy` в Xray (null — не трогать).
  final String? xray;
  final String label;
  const ServerIp(this.xray, this.label);
}

/// Отпечатки uTLS, которые понимает Xray (как выглядит начало TLS-соединения).
const utlsFingerprints = <(String, String)>[
  ('chrome', 'Chrome'),
  ('firefox', 'Firefox'),
  ('safari', 'Safari'),
  ('ios', 'iOS'),
  ('android', 'Android'),
  ('edge', 'Edge'),
  ('360', '360 Browser'),
  ('qq', 'QQ Browser'),
  ('random', 'Случайный браузер'),
  ('randomized', 'Случайный, каждый раз новый'),
];

/// Отпечатки, с которыми работает Reality (проверено e2e на Xray 26).
const realityFingerprints = ['chrome', 'firefox', 'safari'];

/// Включаемые настройки ядра. По умолчанию всё выключено — Bear работает
/// как обычно.
class CoreSettings {
  /// Резать первый пакет TLS (ClientHello) на куски.
  bool fragment;
  String fragmentLength;
  String fragmentInterval;

  /// XHTTP: несколько параллельных соединений к серверу (xmux).
  bool xmux;
  int xmuxConnections;

  /// Несколько серверов одновременно (балансировщик Xray).
  bool multiServer;
  BalanceStrategy strategy;
  int maxServers;

  /// Пускать IPv6-трафик через сервер. Если у сервера нет IPv6, лучше
  /// выключить: программы сразу перейдут на IPv4 вместо долгого ожидания.
  bool ipv6Traffic;

  /// Каким IP подключаться к серверу.
  ServerIp serverIp;

  /// Отпечаток uTLS для всех серверов с TLS/Reality (null — как в ссылке).
  String? fingerprint;

  CoreSettings({
    this.fragment = false,
    this.fragmentLength = '100-200',
    this.fragmentInterval = '10-20',
    this.xmux = false,
    this.xmuxConnections = 6,
    this.multiServer = false,
    this.strategy = BalanceStrategy.fastest,
    this.maxServers = 8,
    this.ipv6Traffic = true,
    this.serverIp = ServerIp.auto,
    this.fingerprint,
  });

  bool get anyEnabled =>
      fragment ||
      xmux ||
      multiServer ||
      !ipv6Traffic ||
      serverIp != ServerIp.auto ||
      fingerprint != null;

  Map<String, Object?> toJson() => {
        'fragment': fragment,
        'fragment_length': fragmentLength,
        'fragment_interval': fragmentInterval,
        'xmux': xmux,
        'xmux_connections': xmuxConnections,
        'multi_server': multiServer,
        'strategy': strategy.name,
        'max_servers': maxServers,
        'ipv6_traffic': ipv6Traffic,
        'server_ip': serverIp.name,
        'fingerprint': fingerprint,
      };

  factory CoreSettings.fromJson(Map<String, Object?> j) {
    final d = CoreSettings();
    return CoreSettings(
      fragment: j['fragment'] as bool? ?? d.fragment,
      fragmentLength: _range(j['fragment_length']) ?? d.fragmentLength,
      fragmentInterval: _range(j['fragment_interval']) ?? d.fragmentInterval,
      xmux: j['xmux'] as bool? ?? d.xmux,
      xmuxConnections:
          ((j['xmux_connections'] as int?) ?? d.xmuxConnections).clamp(1, 32),
      multiServer: j['multi_server'] as bool? ?? d.multiServer,
      strategy: BalanceStrategy.values
              .where((e) => e.name == j['strategy'])
              .firstOrNull ??
          d.strategy,
      maxServers: ((j['max_servers'] as int?) ?? d.maxServers).clamp(2, 20),
      ipv6Traffic: j['ipv6_traffic'] as bool? ?? d.ipv6Traffic,
      serverIp:
          ServerIp.values.where((e) => e.name == j['server_ip']).firstOrNull ??
              d.serverIp,
      fingerprint: utlsFingerprints.any((f) => f.$1 == j['fingerprint'])
          ? j['fingerprint'] as String
          : null,
    );
  }

  /// Диапазон вида «100-200» или «50» — иначе null.
  static String? _range(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return RegExp(r'^\d{1,4}(-\d{1,4})?$').hasMatch(t) ? t : null;
  }

  static bool isValidRange(String v) => _range(v) != null;
}

/// Теги, которые Bear добавляет в конфиг.
const balancerTag = 'bear_auto';

/// Применить настройки к конфигу Xray, собранному для одного сервера.
///
/// [extraProxies] — первые outbound'ы конфигов других серверов (для режима
/// нескольких серверов). Им даются теги `proxy-2`, `proxy-3`…; балансировщик
/// выбирает по префиксу `proxy`.
///
/// Если конфиг не удалось разобрать, он возвращается без изменений и
/// в [log] пишется причина.
String applyCoreSettings(
  String config,
  CoreSettings s, {
  List<Map<String, dynamic>> extraProxies = const [],
  List<String>? log,
}) {
  if (!s.anyEnabled) return config;
  final Map<String, dynamic> j;
  try {
    j = (jsonDecode(config) as Map).cast<String, dynamic>();
  } catch (e) {
    log?.add('настройки: конфиг не разобран, применён без изменений');
    return config;
  }
  final outbounds = [
    for (final o in (j['outbounds'] as List? ?? const []))
      if (o is Map) o.cast<String, dynamic>()
  ];
  if (outbounds.isEmpty) return config;

  // Несколько серверов: добавить outbound'ы остальных серверов сразу после
  // основного.
  final useBalancer = s.multiServer && extraProxies.isNotEmpty;
  if (useBalancer) {
    final first = outbounds.first;
    first['tag'] = 'proxy';
    var n = 2;
    final extra = <Map<String, dynamic>>[];
    for (final o in extraProxies) {
      final copy = (jsonDecode(jsonEncode(o)) as Map).cast<String, dynamic>();
      copy['tag'] = 'proxy-${n++}';
      extra.add(copy);
    }
    outbounds.insertAll(1, extra);
  }

  final proxies = [
    for (final o in outbounds)
      if (!const {'freedom', 'blackhole', 'dns'}.contains(o['protocol'])) o
  ];

  if (s.xmux) {
    var applied = 0;
    for (final o in proxies) {
      final ss = _map(o, 'streamSettings');
      if (ss == null || ss['network'] != 'xhttp') continue;
      final xs = _map(ss, 'xhttpSettings') ?? (ss['xhttpSettings'] = <String, dynamic>{});
      final xmux = {
        'maxConcurrency': 0,
        'maxConnections': s.xmuxConnections,
        'cMaxReuseTimes': 0,
        'hMaxRequestTimes': '600-900',
        'hMaxReusableSecs': '1800-3000',
        'hKeepAlivePeriod': 0,
      };
      xs['xmux'] = xmux;
      final extra = _map(xs, 'extra');
      if (extra != null) extra['xmux'] = xmux;
      applied++;
    }
    log?.add('xmux: ${applied > 0 ? 'включён ($applied)' : 'нет серверов XHTTP'}');
  }

  if (s.fragment) {
    // Xray 26+: фрагментация через finalmask (старый способ — freedom-outbound
    // с dialerProxy — помечен устаревшим и будет удалён).
    var applied = 0;
    for (final o in proxies) {
      final ss = _map(o, 'streamSettings') ?? (o['streamSettings'] = <String, dynamic>{});
      final net = (ss['network'] as String?) ?? 'tcp';
      // Только TCP: Hysteria2, QUIC, KCP идут по UDP.
      if (o['protocol'] == 'hysteria' ||
          o['protocol'] == 'hysteria2' ||
          const {'hysteria', 'quic', 'kcp', 'mkcp'}.contains(net)) {
        continue;
      }
      final fm = _map(ss, 'finalmask') ?? (ss['finalmask'] = <String, dynamic>{});
      final tcp = [
        for (final m in (fm['tcp'] as List? ?? const []))
          if (m is Map && m['type'] != 'fragment') m
      ]..add({
          'type': 'fragment',
          'settings': {
            'packets': 'tlshello',
            'lengths': [s.fragmentLength],
            'delays': [s.fragmentInterval],
          },
        });
      fm['tcp'] = tcp;
      applied++;
    }
    log?.add('fragment: ${applied > 0 ? 'включён ($applied)' : 'нет TCP-серверов'}');
  }

  final fp = s.fingerprint;
  if (fp != null) {
    var applied = 0;
    for (final o in proxies) {
      final ss = _map(o, 'streamSettings');
      if (ss == null) continue;
      final key = switch (ss['security']) {
        'tls' => 'tlsSettings',
        'reality' => 'realitySettings',
        _ => null,
      };
      if (key == null) continue;
      final ts = _map(ss, key) ?? (ss[key] = <String, dynamic>{});
      if (key == 'realitySettings' && !realityFingerprints.contains(fp)) {
        // Проверено на Xray 26: Reality принимает только Chrome, Firefox и
        // Safari, остальные сервер отвергает (отдаёт настоящий сертификат).
        if (fp == 'random' || fp == 'randomized') {
          ts['fingerprint'] = realityFingerprints[
              DateTime.now().microsecondsSinceEpoch % realityFingerprints.length];
        }
        // iOS/Android/Edge/360/QQ: для Reality оставляем отпечаток из ссылки.
      } else {
        ts['fingerprint'] = fp;
      }
      applied++;
    }
    log?.add('отпечаток uTLS: $fp (${applied > 0 ? '$applied' : 'нет серверов с TLS'})');
  }

  if (s.serverIp.xray != null) {
    for (final o in proxies) {
      final ss = _map(o, 'streamSettings') ?? (o['streamSettings'] = <String, dynamic>{});
      final sock = _map(ss, 'sockopt') ?? (ss['sockopt'] = <String, dynamic>{});
      sock['domainStrategy'] = s.serverIp.xray;
    }
    log?.add('подключение к серверу: ${s.serverIp.label}');
  }

  if (!s.ipv6Traffic) {
    final routing = _map(j, 'routing') ?? (j['routing'] = <String, dynamic>{});
    final block = outbounds.firstWhere((o) => o['protocol'] == 'blackhole',
        orElse: () {
      final b = <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'};
      outbounds.add(b);
      return b;
    });
    routing['rules'] = [
      {
        'type': 'field',
        'ip': ['::/0'],
        'outboundTag': block['tag'],
      },
      ...(routing['rules'] as List? ?? const []),
    ];
    log?.add('IPv6 через сервер: выключен');
  }

  if (useBalancer) {
    final routing = _map(j, 'routing') ?? (j['routing'] = <String, dynamic>{});
    final balancers = [
      for (final b in (routing['balancers'] as List? ?? const []))
        if (b is Map && b['tag'] != balancerTag) b
    ]..add({
        'tag': balancerTag,
        'selector': ['proxy'],
        'strategy': {'type': s.strategy.xray},
        'fallbackTag': 'proxy',
      });
    routing['balancers'] = balancers;
    final rules = [
      for (final r in (routing['rules'] as List? ?? const []))
        if (r is Map && r['balancerTag'] != balancerTag) r
    ]..add({
        'type': 'field',
        'network': 'tcp,udp',
        'balancerTag': balancerTag,
      });
    routing['rules'] = rules;
    j['observatory'] = {
      'subjectSelector': ['proxy'],
      'probeUrl': 'https://www.gstatic.com/generate_204',
      'probeInterval': '30s',
      'enableConcurrency': true,
    };
    log?.add('несколько серверов: ${extraProxies.length + 1}, '
        'способ: ${s.strategy.label}');
  }

  j['outbounds'] = outbounds;
  return const JsonEncoder.withIndent('  ').convert(j);
}

Map<String, dynamic>? _map(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is Map<String, dynamic>) return v;
  if (v is Map) {
    final c = v.cast<String, dynamic>();
    m[key] = c;
    return c;
  }
  return null;
}

/// Поправки к конфигу, который строит плагин, — то, что он из ссылки не
/// переносит. Применяются всегда, независимо от настроек.
///
/// * Hysteria2 `obfs=salamander` → `finalmask.udp` (Xray 26+). Без этого
///   к серверу с обфускацией не подключиться.
String applyNodeFixups(String config, ProxyNode node, {List<String>? log}) {
  final salamander = node.protocol == ProxyProtocol.hysteria2 &&
      node.obfs == 'salamander' &&
      (node.obfsPassword ?? '').isNotEmpty;
  if (!salamander) return config;
  try {
    final j = (jsonDecode(config) as Map).cast<String, dynamic>();
    final o = ((j['outbounds'] as List).first as Map).cast<String, dynamic>();
    final ss = _map(o, 'streamSettings') ?? (o['streamSettings'] = <String, dynamic>{});
    final fm = _map(ss, 'finalmask') ?? (ss['finalmask'] = <String, dynamic>{});
    fm['udp'] = [
      for (final m in (fm['udp'] as List? ?? const []))
        if (m is Map && m['type'] != 'salamander') m,
      {
        'type': 'salamander',
        'settings': {'password': node.obfsPassword},
      },
    ];
    (j['outbounds'] as List)[0] = o;
    log?.add('hysteria2: обфускация salamander');
    return const JsonEncoder.withIndent('  ').convert(j);
  } catch (_) {
    log?.add('hysteria2: не удалось добавить salamander');
    return config;
  }
}
