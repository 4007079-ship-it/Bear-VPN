import 'dart:convert';
import 'dart:io';

/// Системный прокси на macOS и Linux (на Windows — WindowsProxyGuard,
/// там прокси прописывает сам плагин).
///
/// Те же правила, что и на Windows: перед подключением запоминаем
/// настройки пользователя, при отключении и при следующем запуске
/// возвращаем их — но только если всё ещё стоит именно наш прокси.
///
/// macOS: `networksetup` для всех включённых сетевых служб (Wi-Fi,
/// Ethernet…). Если система требует прав администратора, спрашиваем
/// пароль один раз стандартным окном macOS.
/// Linux: GNOME/Cinnamon/MATE/Budgie (`gsettings`) и KDE (`kioslaverc`).
class UnixProxyGuard {
  UnixProxyGuard._();

  static String get _home => Platform.environment['HOME'] ?? '/tmp';
  static File get _marker => Platform.isMacOS
      ? File('$_home/Library/Application Support/BearVPN/proxy_guard.json')
      : File('$_home/.config/bear-vpn/proxy_guard.json');

  /// Перед подключением: сохранить настройки пользователя.
  static Future<void> rememberBefore() async {
    try {
      final snap = await _snapshot();
      await _marker.parent.create(recursive: true);
      await _marker.writeAsString(jsonEncode({'prev': snap}));
    } catch (_) {}
  }

  /// Включить наш прокси. Возвращает текст ошибки или null.
  static Future<String?> applyOurs(int httpPort, int? socksPort) async {
    try {
      final err = Platform.isMacOS
          ? await _macApply(httpPort, socksPort)
          : await _linuxApply(httpPort, socksPort);
      if (_marker.existsSync()) {
        final m = jsonDecode(await _marker.readAsString()) as Map<String, Object?>;
        m['our_port'] = httpPort;
        await _marker.writeAsString(jsonEncode(m));
      }
      return err;
    } catch (e) {
      return '$e';
    }
  }

  /// Вернуть настройки пользователя, если всё ещё стоит наш прокси.
  /// Возвращает true, если что-то пришлось исправить.
  static Future<bool> restoreIfOurs() async {
    if (!_marker.existsSync()) return false;
    var fixed = false;
    try {
      final m = jsonDecode(await _marker.readAsString()) as Map<String, Object?>;
      final port = m['our_port'] as int?;
      final prev = (m['prev'] as Map?)?.cast<String, Object?>();
      if (port != null && prev != null && await _isOurs(port)) {
        await _restore(prev);
        fixed = true;
      }
    } catch (_) {}
    try {
      await _marker.delete();
    } catch (_) {}
    return fixed;
  }

  // ---------------------------------------------------------------- общее

  static Future<Map<String, Object?>> _snapshot() async =>
      Platform.isMacOS ? await _macSnapshot() : await _linuxSnapshot();

  static Future<void> _restore(Map<String, Object?> prev) async =>
      Platform.isMacOS ? await _macRestore(prev) : await _linuxRestore(prev);

  static Future<bool> _isOurs(int port) async {
    final cur = await _snapshot();
    if (Platform.isMacOS) {
      for (final s in cur.values) {
        final web = ((s as Map)['web'] as Map?) ?? const {};
        if (web['on'] == true &&
            web['server'] == '127.0.0.1' &&
            web['port'] == '$port') {
          return true;
        }
      }
      return false;
    }
    final g = (cur['gnome'] as Map?) ?? const {};
    if (g['mode'] == "'manual'" &&
        g['http.host'] == "'127.0.0.1'" &&
        g['http.port'] == '$port') {
      return true;
    }
    final k = (cur['kde'] as Map?) ?? const {};
    return k['ProxyType'] == '1' &&
        (k['httpProxy'] ?? '').toString().contains('127.0.0.1') &&
        (k['httpProxy'] ?? '').toString().contains('$port');
  }

  static Future<String> _out(String exe, List<String> args) async {
    final r = await Process.run(exe, args);
    return r.exitCode == 0 ? (r.stdout as String).trim() : '';
  }

  // ---------------------------------------------------------------- macOS

  static const _ns = '/usr/sbin/networksetup';
  static const _kinds = {
    'web': ('-getwebproxy', '-setwebproxy', '-setwebproxystate'),
    'secure': (
      '-getsecurewebproxy',
      '-setsecurewebproxy',
      '-setsecurewebproxystate'
    ),
    'socks': (
      '-getsocksfirewallproxy',
      '-setsocksfirewallproxy',
      '-setsocksfirewallproxystate'
    ),
  };

  static Future<List<String>> _macServices() async {
    final out = await _out(_ns, ['-listallnetworkservices']);
    return [
      for (final l in out.split('\n').skip(1))
        if (l.trim().isNotEmpty && !l.startsWith('*')) l.trim()
    ];
  }

  static Future<Map<String, Object?>> _macSnapshot() async {
    final res = <String, Object?>{};
    for (final svc in await _macServices()) {
      final m = <String, Object?>{};
      for (final e in _kinds.entries) {
        final out = await _out(_ns, [e.value.$1, svc]);
        String? val(String key) => RegExp('^$key: (.*)\$', multiLine: true)
            .firstMatch(out)
            ?.group(1)
            ?.trim();
        m[e.key] = {
          'on': val('Enabled') == 'Yes',
          'server': val('Server') ?? '',
          'port': val('Port') ?? '0',
        };
      }
      res[svc] = m;
    }
    return res;
  }

  /// Выполнить команды networksetup; если без прав не выходит — одним
  /// запросом пароля администратора через osascript.
  static Future<String?> _macRun(List<List<String>> cmds) async {
    var denied = false;
    for (final c in cmds) {
      final r = await Process.run(_ns, c);
      if (r.exitCode != 0) {
        denied = true;
        break;
      }
    }
    if (!denied) return null;
    String q(String s) => "'${s.replaceAll("'", "'\\''")}'";
    final script = cmds.map((c) => '$_ns ${c.map(q).join(' ')}').join(' && ');
    final esc = script.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    final r = await Process.run('/usr/bin/osascript', [
      '-e',
      'do shell script "$esc" with administrator privileges',
    ]);
    return r.exitCode == 0
        ? null
        : 'macOS не дал изменить настройки прокси: ${(r.stderr as String).trim()}';
  }

  static Future<String?> _macApply(int http, int? socks) async {
    final cmds = <List<String>>[];
    for (final svc in await _macServices()) {
      cmds
        ..add(['-setwebproxy', svc, '127.0.0.1', '$http'])
        ..add(['-setsecurewebproxy', svc, '127.0.0.1', '$http']);
      if (socks != null) {
        cmds.add(['-setsocksfirewallproxy', svc, '127.0.0.1', '$socks']);
      }
    }
    return _macRun(cmds);
  }

  static Future<void> _macRestore(Map<String, Object?> prev) async {
    final cmds = <List<String>>[];
    for (final svc in prev.keys) {
      final m = (prev[svc] as Map).cast<String, Object?>();
      for (final e in _kinds.entries) {
        final p = (m[e.key] as Map?) ?? const {};
        final server = (p['server'] ?? '').toString();
        if (p['on'] == true && server.isNotEmpty) {
          cmds.add([e.value.$2, svc, server, '${p['port']}']);
        } else {
          cmds.add([e.value.$3, svc, 'off']);
        }
      }
    }
    await _macRun(cmds);
  }

  // ---------------------------------------------------------------- Linux

  static const _gKeys = [
    ('org.gnome.system.proxy', 'mode', 'mode'),
    ('org.gnome.system.proxy.http', 'host', 'http.host'),
    ('org.gnome.system.proxy.http', 'port', 'http.port'),
    ('org.gnome.system.proxy.https', 'host', 'https.host'),
    ('org.gnome.system.proxy.https', 'port', 'https.port'),
    ('org.gnome.system.proxy.socks', 'host', 'socks.host'),
    ('org.gnome.system.proxy.socks', 'port', 'socks.port'),
  ];

  static bool get _kde =>
      (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '').contains('KDE');

  static Future<String?> _kdeTool(String base) async {
    for (final v in ['6', '5', '']) {
      final r = await Process.run('which', ['$base$v']);
      if (r.exitCode == 0) return '$base$v';
    }
    return null;
  }

  static Future<Map<String, Object?>> _linuxSnapshot() async {
    final g = <String, String>{};
    for (final (schema, key, name) in _gKeys) {
      try {
        g[name] = await _out('gsettings', ['get', schema, key]);
      } catch (_) {}
    }
    final k = <String, String>{};
    if (_kde) {
      final read = await _kdeTool('kreadconfig');
      if (read != null) {
        for (final key in ['ProxyType', 'httpProxy', 'httpsProxy', 'socksProxy']) {
          k[key] = await _out(read,
              ['--file', 'kioslaverc', '--group', 'Proxy Settings', '--key', key]);
        }
      }
    }
    return {'gnome': g, 'kde': k};
  }

  static Future<void> _gset(String schema, String key, String value) async {
    try {
      await Process.run('gsettings', ['set', schema, key, value]);
    } catch (_) {}
  }

  static Future<String?> _linuxApply(int http, int? socks) async {
    var any = false;
    try {
      final r = await Process.run('which', ['gsettings']);
      if (r.exitCode == 0) {
        any = true;
        for (final s in ['http', 'https']) {
          await _gset('org.gnome.system.proxy.$s', 'host', '127.0.0.1');
          await _gset('org.gnome.system.proxy.$s', 'port', '$http');
        }
        if (socks != null) {
          await _gset('org.gnome.system.proxy.socks', 'host', '127.0.0.1');
          await _gset('org.gnome.system.proxy.socks', 'port', '$socks');
        }
        await _gset('org.gnome.system.proxy', 'mode', 'manual');
      }
    } catch (_) {}
    if (_kde) {
      final write = await _kdeTool('kwriteconfig');
      if (write != null) {
        any = true;
        Future<void> kw(String key, String v) => Process.run(write, [
              '--file', 'kioslaverc', '--group', 'Proxy Settings', //
              '--key', key, v,
            ]);
        await kw('httpProxy', 'http://127.0.0.1 $http');
        await kw('httpsProxy', 'http://127.0.0.1 $http');
        if (socks != null) await kw('socksProxy', 'socks://127.0.0.1 $socks');
        await kw('ProxyType', '1');
        await _kdeReload();
      }
    }
    return any
        ? null
        : 'Не найден способ включить системный прокси в этой среде рабочего '
            'стола. Используйте режим «Прокси» и укажите порт в программах.';
  }

  static Future<void> _kdeReload() async {
    try {
      await Process.run('dbus-send', [
        '--type=signal', '/KIO/Scheduler', //
        'org.kde.KIO.Scheduler.reparseSlaveConfiguration', 'string:',
      ]);
    } catch (_) {}
  }

  static Future<void> _linuxRestore(Map<String, Object?> prev) async {
    final g = ((prev['gnome'] as Map?) ?? const {}).cast<String, Object?>();
    for (final (schema, key, name) in _gKeys.reversed) {
      final v = g[name]?.toString() ?? '';
      if (v.isNotEmpty) await _gset(schema, key, v);
    }
    final k = ((prev['kde'] as Map?) ?? const {}).cast<String, Object?>();
    if (k.isNotEmpty) {
      final write = await _kdeTool('kwriteconfig');
      if (write != null) {
        for (final e in k.entries) {
          await Process.run(write, [
            '--file', 'kioslaverc', '--group', 'Proxy Settings', //
            '--key', e.key, '${e.value}',
          ]);
        }
        await _kdeReload();
      }
    }
  }
}
