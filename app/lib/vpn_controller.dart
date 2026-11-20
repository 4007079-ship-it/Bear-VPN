import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

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
    if (next == VpnState.disconnected) activeNodeId = null;
    state = next;
    duration = Duration(seconds: _i(s.duration));
    upload = _i(s.upload);
    download = _i(s.download);
    uploadSpeed = _i(s.uploadSpeed);
    downloadSpeed = _i(s.downloadSpeed);
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
      final config = parsed.getFullConfiguration();

      if (!proxyOnlyMode) {
        final allowed = await _vless.requestPermission();
        if (!allowed) {
          throw Exception('Нет разрешения на VPN');
        }
      }
      if (state == VpnState.connected) {
        await _vless.stopVless();
      }
      await _vless.startVless(
        remark: node.name,
        config: config,
        proxyOnly: proxyOnlyMode,
        notificationDisconnectButtonName: 'Отключить',
      );
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
      notifyListeners();
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
