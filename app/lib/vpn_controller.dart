import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

import 'windows_proxy_guard.dart';

enum VpnState { disconnected, connecting, connected, disconnecting }

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
    if (!Platform.isWindows) return;
    if (await WindowsProxyGuard.restoreIfOurs()) {
      info = 'Прошлый сеанс завершился без отключения — настройки прокси '
          'Windows восстановлены, интернет работает напрямую.';
      notifyListeners();
    }
  }

  /// При закрытии окна: отключиться и вернуть настройки прокси.
  Future<void> shutdown() async {
    if (state != VpnState.disconnected) {
      try {
        await _vless.stopVless().timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    if (Platform.isWindows) await WindowsProxyGuard.restoreIfOurs();
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
    // Подключение уже подтверждено проверкой — не откатываемся на
    // «Подключение…» из-за запоздалых статусов плагина.
    if (proxyOnlyMode &&
        _connectedAt != null &&
        state == VpnState.connected &&
        next == VpnState.connecting) {
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

  Future<void> connect(ProxyNode node) async {
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
      notifyListeners();

      await _init();
      final parsed = FlutterVless.parseFromURL(nodeToUri(node));
      final baseConfig = parsed.getFullConfiguration();
      final config = await _withMetrics(baseConfig);

      if (!proxyOnlyMode) {
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
      try {
        await _vless.startVless(
          remark: node.name,
          config: config,
          proxyOnly: proxyOnlyMode,
          notificationDisconnectButtonName: 'Отключить',
        );
      } catch (_) {
        if (identical(config, baseConfig)) rethrow;
        // Конфиг со статистикой не принят — запускаемся без неё.
        _metricsPort = null;
        await _vless.startVless(
          remark: node.name,
          config: baseConfig,
          proxyOnly: proxyOnlyMode,
          notificationDisconnectButtonName: 'Отключить',
        );
      }
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

  Future<void> _confirmByProbe(String nodeId) async {
    final started = DateTime.now();
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (state != VpnState.connecting || activeNodeId != nodeId) return;
      int d;
      try {
        d = _i(await _vless.getConnectedServerDelay());
      } catch (_) {
        d = -1;
      }
      if (d > 0 && state == VpnState.connecting && activeNodeId == nodeId) {
        state = VpnState.connected;
        delayMs = d;
        error = null;
        _connectedAt = started;
        unawaited(WindowsProxyGuard.rememberOurs());
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
  Set<String> _proxyTags = const {};
  Timer? _statsTimer;
  bool _metricsOk = false;
  int _lastUp = 0, _lastDown = 0;
  DateTime? _lastSample;

  /// Добавляет в Xray-конфиг stats + metrics на свободном локальном порту.
  /// Если конфиг не удалось разобрать — возвращает его без изменений.
  Future<String> _withMetrics(String config) async {
    _metricsPort = null;
    _metricsOk = false;
    try {
      final j = jsonDecode(config);
      if (j is! Map<String, dynamic>) return config;
      if (j.containsKey('metrics') || j.containsKey('stats')) return config;
      final outbounds = (j['outbounds'] as List?) ?? const [];
      _proxyTags = {
        for (final o in outbounds)
          if (o is Map &&
              o['tag'] is String &&
              !const {'freedom', 'blackhole', 'dns'}.contains(o['protocol']))
            o['tag'] as String,
      };
      if (_proxyTags.isEmpty) return config;

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
      await _vless.stopVless();
    } catch (e) {
      error = _humanError(e);
    } finally {
      if (proxyOnlyMode) await WindowsProxyGuard.restoreIfOurs();
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
      ..writeln('Режим: ${proxyOnlyMode ? 'системный прокси' : 'VPN'}')
      ..writeln('Состояние: ${state.name}');
    if (Platform.isWindows) {
      final dir = File(Platform.resolvedExecutable).parent.path;
      for (final f in ['xray\\xray.exe', 'xray\\geoip.dat', 'xray\\geosite.dat']) {
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
    if (error != null) b.writeln('Последняя ошибка: $error');
    return b.toString();
  }

  Future<void> measureDelay() async {
    try {
      delayMs = _i(await _vless.getConnectedServerDelay());
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
