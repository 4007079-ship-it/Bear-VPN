import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'windows_proxy_guard.dart';

enum VpnState { disconnected, connecting, connected, disconnecting }

/// Как приложение пускает трафик через сервер.
enum ConnectionMode {
  /// Только локальный порт: программы настраиваются на него вручную.
  proxy,

  /// Windows: системный прокси (браузеры и большинство программ).
  systemProxy,

  /// Весь трафик устройства (Android VpnService, Windows TUN — нужны права
  /// администратора).
  vpn;

  String get label => switch (this) {
        ConnectionMode.proxy => 'Прокси',
        ConnectionMode.systemProxy => 'Системный прокси',
        ConnectionMode.vpn => 'VPN',
      };

  /// Режимы, доступные на этой платформе.
  static List<ConnectionMode> get available => Platform.isWindows
      ? const [ConnectionMode.proxy, ConnectionMode.systemProxy, ConnectionMode.vpn]
      : const [ConnectionMode.proxy, ConnectionMode.vpn];
}

/// Подключение через ядро Xray (плагин flutter_vless).
///
/// Android — режим VPN (VpnService), весь трафик устройства.
/// Windows — режим системного прокси: без прав администратора и без
/// VPN-адаптера; работают браузеры и программы, учитывающие системный прокси.
///
/// Тестовая сборка: AmneziaWG, WireGuard, TUIC и HTTP-прокси ядро Xray
/// здесь не запускает — для них нужен отдельный движок.
class VpnController extends ChangeNotifier {
  late final FlutterVless _vless =
      FlutterVless(onStatusChanged: _onStatus);
  bool _initialized = false;
  Timer? _watchdog;

  VpnState state = VpnState.disconnected;
  String? activeNodeId;
  String? error;

  /// Информационное сообщение (не ошибка), например о восстановлении прокси.
  String? info;
  Duration duration = Duration.zero;
  int upload = 0;
  int download = 0;
  int uploadSpeed = 0;
  int downloadSpeed = 0;
  int? delayMs;

  static bool get proxyOnlyMode => Platform.isWindows;

  /// Можно ли подключиться к узлу в этой сборке.
  static String? unsupportedReason(ProxyNode n) => switch (n.protocol) {
        ProxyProtocol.amneziawg ||
        ProxyProtocol.wireguard =>
          'AmneziaWG/WireGuard: подключение появится в следующей сборке '
              '(нужен движок amneziawg-go)',
        ProxyProtocol.tuic => 'TUIC не поддерживается ядром Xray',
        ProxyProtocol.http => 'HTTP-прокси пока не поддерживается',
        _ => null,
      };

  /// При запуске: если прошлый сеанс оставил наш системный прокси
  /// (приложение закрыли без «Отключить» или оно упало) — вернуть настройки.
  Future<void> recoverOnStartup() async {
    if (!Platform.isWindows) {
      // Android: VPN-служба живёт отдельно от экрана. После сворачивания или
      // перезапуска приложения сразу подписываемся на её статусы, чтобы
      // показать «Подключено», если соединение уже работает.
      try {
        await _init();
      } catch (_) {}
      return;
    }
    await killOwnXray();
    // После аварийного завершения в режиме VPN мог остаться tun2socks с
    // маршрутами на уже мёртвое ядро — завершаем и его.
    await killOwnXray(name: 'tun2socks');
    if (await WindowsProxyGuard.restoreIfOurs()) {
      info = 'Прошлый сеанс завершился без отключения — настройки прокси '
          'Windows восстановлены, интернет работает напрямую.';
      notifyListeners();
    }
  }

  /// При закрытии окна: отключиться и вернуть настройки прокси.
  Future<void> shutdown() async {
    final winVpn = Platform.isWindows && _activeMode == ConnectionMode.vpn;
    if (state != VpnState.disconnected) {
      try {
        await _vless
            .stopVless()
            .timeout(Duration(seconds: winVpn ? 10 : 2));
      } catch (_) {}
    }
    if (Platform.isWindows) {
      if (!winVpn) await killOwnXray();
      await WindowsProxyGuard.restoreIfOurs();
    }
  }

  Future<void> _init() async {
    if (_initialized) return;
    await _vless.initializeVless(
      notificationIconResourceType: 'mipmap',
      notificationIconResourceName: 'ic_launcher',
      providerBundleIdentifier: 'com.smv.smvVpn',
      groupIdentifier: 'group.com.smv.smvVpn',
    );
    _initialized = true;
  }

  void _onStatus(VlessStatus s) {
    final next = switch (s.connectionState) {
      VlessConnectionState.connected => VpnState.connected,
      VlessConnectionState.connecting => VpnState.connecting,
      VlessConnectionState.disconnecting => VpnState.disconnecting,
      _ => VpnState.disconnected,
    };
    // Windows (системный прокси): статусы плагина ненадёжны — состоянием
    // управляет само приложение по своей проверке связи.
    if (proxyOnlyMode) {
      if (!_metricsOk) {
        upload = _i(s.upload);
        download = _i(s.download);
        uploadSpeed = _i(s.uploadSpeed);
        downloadSpeed = _i(s.downloadSpeed);
        notifyListeners();
      }
      return;
    }
    if (next == VpnState.disconnected) {
      activeNodeId = null;
      _connectedAt = null;
    }
    state = next;
    final pd = _i(s.duration);
    if (pd > 0 || _connectedAt == null) duration = Duration(seconds: pd);
    // Счётчики плагина используем, только если собственная статистика
    // ядра (metrics) недоступна.
    if (!_metricsOk) {
      upload = _i(s.upload);
      download = _i(s.download);
      uploadSpeed = _i(s.uploadSpeed);
      downloadSpeed = _i(s.downloadSpeed);
    }
    if (next == VpnState.connected) _startStats();
    if (next == VpnState.disconnected) _stopStats();
    notifyListeners();
  }

  bool _busy = false;
  ConnectionMode? _activeMode;

  ConnectionMode mode =
      Platform.isWindows ? ConnectionMode.systemProxy : ConnectionMode.vpn;

  /// Локальные порты ядра (для режима «Прокси»).
  int? httpPort;
  int? socksPort;

  static const _modeKey = 'bear.mode.v1';
  static const _prefs = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true));

  Future<void> loadMode() async {
    try {
      final v = await _prefs.read(key: _modeKey);
      final m = ConnectionMode.values.where((e) => e.name == v).firstOrNull;
      if (m != null && ConnectionMode.available.contains(m)) mode = m;
    } catch (_) {}
  }

  void setMode(ConnectionMode m) {
    if (state != VpnState.disconnected || m == mode) return;
    mode = m;
    error = null;
    notifyListeners();
    _prefs.write(key: _modeKey, value: m.name).catchError((Object _) {});
  }

  /// Windows: запущено ли приложение с правами администратора.
  static Future<bool> isWindowsAdmin() async {
    if (!Platform.isWindows) return true;
    try {
      final r = await Process.run('net', ['session'])
          .timeout(const Duration(seconds: 5));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Перезапустить Bear с правами администратора (нужно для VPN на Windows).
  Future<void> relaunchAsAdmin() async {
    final exe = Platform.resolvedExecutable.replaceAll("'", "''");
    await Process.start('powershell', [
      '-NoProfile',
      '-Command',
      "Start-Process -FilePath '$exe' -Verb RunAs",
    ]);
    await shutdown();
    exit(0);
  }

  /// Экспериментально (Windows): добавлять в конфиг статистику трафика.
  /// Включено по умолчанию (проверено на Windows 10/11); выключатель в «Логах».
  bool windowsStats = true;

  void setWindowsStats(bool v) {
    windowsStats = v;
    notifyListeners();
  }

  Future<void> connect(ProxyNode node) async {
    if (_busy) return;
    _busy = true;
    try {
      await _connect(node);
    } finally {
      _busy = false;
    }
  }

  Future<void> _connect(ProxyNode node) async {
    error = null;
    delayMs = null;
    final reason = unsupportedReason(node);
    if (reason != null) {
      error = reason;
      notifyListeners();
      return;
    }
    try {
      state = VpnState.connecting;
      activeNodeId = node.id;
      _activeMode = mode;
      notifyListeners();

      await _init();
      final parsed = FlutterVless.parseFromURL(nodeToUri(node));
      final baseConfig = parsed.getFullConfiguration();
      _startLog.clear();
      if (proxyOnlyMode) {
        await _connectWindows(node, baseConfig);
        return;
      }

      if (mode == ConnectionMode.vpn) {
        final allowed = await _vless.requestPermission();
        if (!allowed) {
          throw Exception('Нет разрешения на VPN');
        }
      }
      if (proxyOnlyMode) {
        await WindowsProxyGuard.restoreIfOurs();
        await WindowsProxyGuard.rememberBefore();
      }
      info = null;
      upload = download = uploadSpeed = downloadSpeed = 0;
      // Пробуем по очереди: со статистикой и проверкой связи → только
      // с проверкой связи → исходный конфиг. Перед повтором обязательно
      // останавливаем сессию: плагин не меняет конфиг на лету.
      // Сбросить сессию, оставшуюся от прошлого запуска приложения
      // (иначе плагин отвечает «Stop the active session…» и не стартует).
      try {
        await _vless.stopVless().timeout(const Duration(seconds: 5));
        _startLog.add('сброс прошлой сессии: ок');
      } catch (e) {
        _startLog.add('сброс прошлой сессии: ${_humanError(e)}');
      }
      notifyListeners();
      Object? lastError;
      var started = false;
      for (final (metrics, probe, label) in const [
        (true, true, 'статистика + проверка'),
        (false, true, 'только проверка'),
        (false, false, 'исходный конфиг'),
      ]) {
        final config =
            await _withExtras(baseConfig, metrics: metrics, probe: probe);
        httpPort = _httpInboundPort(baseConfig) ?? _probePort;
        socksPort = _inboundPort(baseConfig, 'socks');
        try {
          _startLog.add('$label: запуск…');
          await _vless
              .startVless(
                remark: node.name,
                config: config,
                proxyOnly: mode == ConnectionMode.proxy,
                notificationDisconnectButtonName: 'Отключить',
              )
              .timeout(const Duration(seconds: 20),
                  onTimeout: () => throw TimeoutException(
                      'ядро не ответило за 20 с'));
          _startLog.add('$label: запущено');
          started = true;
          break;
        } catch (e) {
          lastError = e;
          _startLog.add('$label: ${_humanError(e)}');
          try {
            await _vless.stopVless().timeout(const Duration(seconds: 5));
          } catch (_) {}
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      if (!started) throw lastError ?? Exception('Не удалось запустить ядро');
      // Windows (системный прокси): плагин может не прислать статус
      // CONNECTED, хотя прокси уже работает. Проверяем сами: если запрос
      // через активное ядро проходит — считаем подключение установленным.
      if (proxyOnlyMode) unawaited(_confirmByProbe(node.id));
      _watchdog?.cancel();
      _watchdog = Timer(const Duration(seconds: 20), () {
        if (state == VpnState.connecting) {
          error = 'За 20 секунд подключение не установилось. '
              'Нажмите «Диагностика» и пришлите текст.';
          notifyListeners();
        }
      });
    } catch (e) {
      state = VpnState.disconnected;
      activeNodeId = null;
      error = _humanError(e);
      if (proxyOnlyMode) await WindowsProxyGuard.restoreIfOurs();
      notifyListeners();
    }
  }

  /// Windows: плагин может так и не завершить startVless, хотя прокси уже
  /// работает. Поэтому не ждём его, а проверяем связь сами.
  Future<void> _connectWindows(ProxyNode node, String baseConfig) async {
    final vpnMode = mode == ConnectionMode.vpn;
    if (vpnMode && !await isWindowsAdmin()) {
      throw Exception('Для режима VPN запустите Bear от имени администратора '
          '(кнопка ниже) или выберите «Системный прокси».');
    }
    await _resetWindowsCore();
    await WindowsProxyGuard.restoreIfOurs();
    await WindowsProxyGuard.rememberBefore();
    info = null;
    upload = download = uploadSpeed = downloadSpeed = 0;

    String config;
    if (windowsStats) {
      config = await _withExtras(baseConfig, metrics: true, probe: true);
    } else {
      config = baseConfig;
      _metricsPort = null;
      _probePort = _httpInboundPort(baseConfig);
      if (_probePort == null) {
        config = await _withExtras(baseConfig, metrics: false, probe: true);
      }
    }
    httpPort = _httpInboundPort(baseConfig) ?? _probePort;
    socksPort = _inboundPort(baseConfig, 'socks');
    _startLog.add('режим подключения: ${mode.label}');
    _startLog.add('статистика: ${windowsStats ? 'да' : 'нет'}, '
        'порт проверки: ${_probePort ?? 'нет'}, '
        'HTTP: ${httpPort ?? '-'}, SOCKS: ${socksPort ?? '-'}');

    final nodeId = node.id;
    unawaited(_vless
        .startVless(
          remark: node.name,
          config: config,
          proxyOnly: !vpnMode,
          notificationDisconnectButtonName: 'Отключить',
        )
        .then((_) => _startLog.add('startVless: завершён'),
            onError: (Object e) {
      _startLog.add('startVless: ${_humanError(e)}');
      if (state == VpnState.connecting && activeNodeId == nodeId) {
        error = _humanError(e);
        notifyListeners();
      }
    }));
    unawaited(_confirmByProbe(nodeId));
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 25), () {
      if (state == VpnState.connecting && activeNodeId == nodeId) {
        error = 'За 25 секунд связь через сервер не появилась. '
            'Откройте «Логи» и пришлите текст.';
        notifyListeners();
      }
    });
  }

  /// Порт HTTP-входа из конфига плагина (на него указывает системный прокси).
  static int? _httpInboundPort(String config) => _inboundPort(config, 'http');

  static int? _inboundPort(String config, String protocol) {
    try {
      final j = jsonDecode(config) as Map<String, dynamic>;
      for (final ib in (j['inbounds'] as List? ?? const [])) {
        if (ib is Map && ib['protocol'] == protocol && ib['tag'] != 'smv_probe') {
          final p = ib['port'];
          if (p is int) return p;
          if (p is String) return int.tryParse(p);
        }
      }
    } catch (_) {}
    return null;
  }

  /// Остановить сессию плагина; если он не отвечает — завершить наш
  /// xray.exe (только из папки приложения, чужие клиенты не трогаем).
  Future<void> _resetWindowsCore() async {
    try {
      await _vless.stopVless().timeout(const Duration(seconds: 3));
      _startLog.add('остановка сессии: ок');
    } catch (e) {
      _startLog.add('остановка сессии: ${_humanError(e)}');
    }
    final killed = await killOwnXray();
    if (killed > 0) _startLog.add('завершено зависших xray.exe: $killed');
  }

  static Future<int> killOwnXray({String name = 'xray'}) async {
    if (!Platform.isWindows) return 0;
    try {
      final dir = File(Platform.resolvedExecutable).parent.path;
      final xray = '$dir\\xray\\$name.exe'.replaceAll("'", "''");
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "\$p = Get-Process $name -ErrorAction SilentlyContinue | "
            "Where-Object { \$_.Path -eq '$xray' }; "
            "\$p | Stop-Process -Force -ErrorAction SilentlyContinue; "
            "(\$p | Measure-Object).Count",
      ]).timeout(const Duration(seconds: 10));
      return int.tryParse((r.stdout as String).trim()) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _confirmByProbe(String nodeId) async {
    final started = DateTime.now();
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (state != VpnState.connecting || activeNodeId != nodeId) return;
      int d = await _probeOnce();
      if (d <= 0) {
        try {
          d = _i(await _vless.getConnectedServerDelay());
        } catch (_) {
          d = -1;
        }
      }
      if (d > 0 && state == VpnState.connecting && activeNodeId == nodeId) {
        state = VpnState.connected;
        delayMs = d;
        error = null;
        _connectedAt = started;
        if (mode == ConnectionMode.proxy) {
          // Режим «Прокси»: ядро работает на локальных портах, а системный
          // прокси Windows возвращаем как было.
          unawaited(WindowsProxyGuard.restorePrevious());
        } else if (mode == ConnectionMode.systemProxy) {
          unawaited(WindowsProxyGuard.rememberOurs());
        }
        _startStats();
        _ticker?.cancel();
        _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
          if (state != VpnState.connected) {
            _ticker?.cancel();
            return;
          }
          duration = DateTime.now().difference(_connectedAt!);
          notifyListeners();
        });
        notifyListeners();
        return;
      }
    }
  }

  DateTime? _connectedAt;
  Timer? _ticker;

  // ---------------------------------------------------------------------
  // Статистика трафика из ядра Xray (metrics → /debug/vars).
  // Не зависит от того, присылает ли плагин счётчики на этой платформе.

  int? _metricsPort;
  int? _probePort;

  /// Запрос через ядро (наш HTTP-вход) → задержка в мс или -1.
  Future<int> _probeOnce() async {
    final port = _probePort;
    if (port == null) return -1;
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY 127.0.0.1:$port')
      ..connectionTimeout = const Duration(seconds: 6);
    final sw = Stopwatch()..start();
    try {
      final req = await client
          .getUrl(Uri.parse('https://www.gstatic.com/generate_204'))
          .timeout(const Duration(seconds: 8));
      final res = await req.close().timeout(const Duration(seconds: 8));
      await res.drain<void>();
      return (res.statusCode == 204 || res.statusCode == 200)
          ? sw.elapsedMilliseconds
          : -1;
    } catch (_) {
      return -1;
    } finally {
      client.close(force: true);
    }
  }

  Set<String> _proxyTags = const {};
  Timer? _statsTimer;
  bool _metricsOk = false;
  int _lastUp = 0, _lastDown = 0;
  DateTime? _lastSample;

  /// Добавляет в Xray-конфиг stats + metrics на свободном локальном порту.
  /// Если конфиг не удалось разобрать — возвращает его без изменений.
  final List<String> _startLog = [];

  Future<String> _withExtras(String config,
      {required bool metrics, required bool probe}) async {
    _metricsPort = null;
    _probePort = null;
    _metricsOk = false;
    if (!metrics && !probe) return config;
    try {
      final j = jsonDecode(config);
      if (j is! Map<String, dynamic>) return config;

      // Свой HTTP-вход на свободном порту: через него приложение само
      // проверяет, что соединение через сервер реально работает.
      final probeSock =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final probePort = probeSock.port;
      await probeSock.close();
      final inbounds = List<Object?>.from((j['inbounds'] as List?) ?? const []);
      inbounds.add({
        'tag': 'smv_probe',
        'listen': '127.0.0.1',
        'port': probePort,
        'protocol': 'http',
        'settings': <String, dynamic>{},
      });
      j['inbounds'] = inbounds;
      _probePort = probePort;

      if (!metrics || j.containsKey('metrics') || j.containsKey('stats')) {
        return jsonEncode(j);
      }
      final outbounds = (j['outbounds'] as List?) ?? const [];
      _proxyTags = {
        for (final o in outbounds)
          if (o is Map &&
              o['tag'] is String &&
              !const {'freedom', 'blackhole', 'dns'}.contains(o['protocol']))
            o['tag'] as String,
      };
      if (_proxyTags.isEmpty) return jsonEncode(j);

      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();

      j['stats'] = <String, dynamic>{};
      j['metrics'] = {'tag': 'smv_metrics', 'listen': '127.0.0.1:$port'};
      final policy = (j['policy'] as Map<String, dynamic>?) ?? {};
      final system = (policy['system'] as Map<String, dynamic>?) ?? {};
      system['statsOutboundUplink'] = true;
      system['statsOutboundDownlink'] = true;
      policy['system'] = system;
      j['policy'] = policy;
      _metricsPort = port;
      return jsonEncode(j);
    } catch (_) {
      return config;
    }
  }

  void _startStats() {
    if (_metricsPort == null || _statsTimer != null) return;
    _lastSample = null;
    _statsTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _pollStats());
  }

  void _stopStats() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _metricsOk = false;
  }

  Future<void> _pollStats() async {
    final port = _metricsPort;
    if (port == null || state != VpnState.connected) return;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final req = await client.get('127.0.0.1', port, '/debug/vars');
      final res = await req.close().timeout(const Duration(seconds: 2));
      final body = await res.transform(utf8.decoder).join();
      final stats = (jsonDecode(body) as Map)['stats'];
      final out = stats is Map ? stats['outbound'] : null;
      if (out is! Map) return;
      var up = 0, down = 0;
      for (final tag in _proxyTags) {
        final t = out[tag];
        if (t is Map) {
          up += _i(t['uplink']);
          down += _i(t['downlink']);
        }
      }
      final now = DateTime.now();
      final last = _lastSample;
      if (last != null) {
        final secs = now.difference(last).inMilliseconds / 1000;
        if (secs > 0) {
          uploadSpeed = ((up - _lastUp).clamp(0, 1 << 62) / secs).round();
          downloadSpeed = ((down - _lastDown).clamp(0, 1 << 62) / secs).round();
        }
      }
      _lastSample = now;
      _lastUp = up;
      _lastDown = down;
      upload = up;
      download = down;
      _metricsOk = true;
      notifyListeners();
    } catch (_) {
      // ядро ещё не подняло metrics или порт занят — попробуем позже
    } finally {
      client.close(force: true);
    }
  }

  Future<void> disconnect() async {
    try {
      state = VpnState.disconnecting;
      notifyListeners();
      // Windows VPN (TUN): ядро обязано само снять маршруты и адаптер,
      // поэтому ждём дольше и процесс не убиваем.
      final winVpn = proxyOnlyMode && _activeMode == ConnectionMode.vpn;
      await _vless.stopVless().timeout(Duration(
          seconds: winVpn ? 15 : (proxyOnlyMode ? 4 : 10)));
    } catch (e) {
      if (!proxyOnlyMode) error = _humanError(e);
      if (proxyOnlyMode && _activeMode == ConnectionMode.vpn) {
        error = 'Ядро долго не отключало VPN. Если интернет пропал — '
            'перезапустите Bear или компьютер.';
      }
    } finally {
      if (proxyOnlyMode) {
        if (_activeMode != ConnectionMode.vpn) await killOwnXray();
        await WindowsProxyGuard.restoreIfOurs();
      }
      _activeMode = null;
      _stopStats();
      _watchdog?.cancel();
      _ticker?.cancel();
      _connectedAt = null;
      state = VpnState.disconnected;
      activeNodeId = null;
      notifyListeners();
    }
  }

  /// Диагностика для отладки: версия ядра, наличие xray.exe, журнал плагина.
  /// Конфиг и ключи плагин в журнал не пишет.
  Future<String> diagnostics() async {
    final b = StringBuffer()
      ..writeln('Платформа: ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}')
      ..writeln('Режим: ${mode.label}')
      ..writeln('Состояние: ${state.name}');
    if (Platform.isWindows) {
      final dir = File(Platform.resolvedExecutable).parent.path;
      for (final f in [
        'xray\\xray.exe',
        'xray\\geoip.dat',
        'xray\\geosite.dat',
        'xray\\tun2socks.exe',
        'xray\\wintun.dll',
      ]) {
        b.writeln('$f: ${File('$dir\\$f').existsSync() ? 'есть' : 'НЕТ'}');
      }
    }
    try {
      await _init();
      b.writeln('Ядро: ${await _vless.getCoreVersion()}');
    } catch (e) {
      b.writeln('Ядро: ошибка — ${_humanError(e)}');
    }
    try {
      final snap = await _vless.getProviderDebugSnapshot();
      b
        ..writeln('--- журнал плагина ---')
        ..writeln(snap.toString().isEmpty ? '(пусто)' : snap);
    } catch (e) {
      b.writeln('Журнал: ошибка — ${_humanError(e)}');
    }
    if (_startLog.isNotEmpty) {
      b.writeln('--- запуск ядра ---');
      _startLog.forEach(b.writeln);
    }
    if (error != null) b.writeln('Последняя ошибка: $error');
    return b.toString();
  }

  Future<void> measureDelay() async {
    try {
      final own = await _probeOnce();
      delayMs = own > 0 ? own : _i(await _vless.getConnectedServerDelay());
    } catch (_) {
      delayMs = -1;
    }
    notifyListeners();
  }

  static int _i(Object? v) => switch (v) {
        int x => x,
        num x => x.toInt(),
        String x => int.tryParse(x) ?? 0,
        _ => 0,
      };

  static String _humanError(Object e) {
    final s = e.toString();
    // Конфиг и ключи в текст ошибки не попадают: показываем только начало.
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }
}

String formatBytes(int b) {
  if (b < 1024) return '$b Б';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} КБ';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / 1024 / 1024).toStringAsFixed(1)} МБ';
  }
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} ГБ';
}

String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}
