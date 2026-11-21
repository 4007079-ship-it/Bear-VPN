import 'dart:convert';
import 'dart:io';

/// Защита от «пропавшего интернета» на Windows.
///
/// В режиме системного прокси Windows направляет трафик на локальный порт
/// Xray. Если приложение закрыли без «Отключить» или оно упало, настройка
/// остаётся, и сайты перестают открываться. Поэтому:
///  * перед подключением запоминаем прежние настройки прокси пользователя;
///  * после подключения запоминаем, какой прокси прописало приложение;
///  * при отключении и при следующем запуске возвращаем прежние настройки,
///    но только если в Windows всё ещё стоит именно наш прокси — чужие
///    настройки (другой клиент, корпоративный прокси) не трогаем.
class WindowsProxyGuard {
  static const _key =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  static File? get _markerFile {
    final appData = Platform.environment['APPDATA'];
    if (appData == null) return null;
    return File('$appData\\SMV-VPN\\proxy_guard.json');
  }

  /// Текущие настройки: (включён ли прокси, адрес).
  static Future<(bool, String?)> read() async {
    final enable = await _query('ProxyEnable');
    final server = await _query('ProxyServer');
    final on = enable != null && (enable.endsWith('0x1') || enable == '1');
    return (on, server);
  }

  static Future<String?> _query(String name) async {
    try {
      final r = await Process.run('reg', ['query', _key, '/v', name]);
      if (r.exitCode != 0) return null;
      for (final line in (r.stdout as String).split(RegExp(r'\r?\n'))) {
        final t = line.trim();
        if (!t.startsWith(name)) continue;
        final parts = t.split(RegExp(r'\s+'));
        return parts.length >= 3 ? parts.sublist(2).join(' ') : '';
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _write(bool enable, String? server) async {
    await Process.run('reg', [
      'add', _key, '/v', 'ProxyEnable', '/t', 'REG_DWORD', //
      '/d', enable ? '1' : '0', '/f',
    ]);
    if (server != null && server.isNotEmpty) {
      await Process.run('reg', [
        'add', _key, '/v', 'ProxyServer', '/t', 'REG_SZ', //
        '/d', server, '/f',
      ]);
    }
  }

  /// Перед подключением: сохранить настройки пользователя.
  static Future<void> rememberBefore() async {
    final f = _markerFile;
    if (f == null) return;
    final (on, server) = await read();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({
      'prev_enable': on,
      'prev_server': server,
    }));
  }

  /// После подключения: запомнить прокси, который прописал Xray.
  static Future<void> rememberOurs() async {
    final f = _markerFile;
    if (f == null || !f.existsSync()) return;
    final (on, server) = await read();
    if (!on || server == null) return;
    final m = jsonDecode(await f.readAsString()) as Map<String, Object?>;
    m['our_server'] = server;
    await f.writeAsString(jsonEncode(m));
  }

  /// Вернуть настройки пользователя, если в Windows остался наш прокси.
  /// Возвращает true, если что-то пришлось исправить.
  static Future<bool> restoreIfOurs() async {
    final f = _markerFile;
    if (f == null || !f.existsSync()) return false;
    var fixed = false;
    try {
      final m = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      final ours = m['our_server'] as String?;
      final (on, server) = await read();
      final stillOurs = on &&
          server != null &&
          (ours != null
              ? server == ours
              : server.contains('127.0.0.1') || server.contains('localhost'));
      if (stillOurs) {
        await _write(
            m['prev_enable'] == true, m['prev_server'] as String?);
        fixed = true;
      }
    } catch (_) {
      // повреждённый файл — просто удаляем ниже
    }
    try {
      await f.delete();
    } catch (_) {}
    return fixed;
  }
}
