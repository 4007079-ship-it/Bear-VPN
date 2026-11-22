import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Linux: у плагина нет реализации для Linux, поэтому ядро Xray запускаем
/// сами — отдельным процессом из папки приложения (`xray/xray`).
///
/// Конфиг с ключами пишется в ~/.config/bear-vpn/run.json с правами 600
/// и удаляется при остановке.
class LinuxXray {
  LinuxXray._();

  static Process? _proc;
  static final List<String> recentOutput = [];

  static String get _home => Platform.environment['HOME'] ?? '/tmp';
  static String get coreDir =>
      '${File(Platform.resolvedExecutable).parent.path}/xray';
  static String get exe => '$coreDir/xray';
  static Directory get _stateDir => Directory('$_home/.config/bear-vpn');
  static File get _config => File('${_stateDir.path}/run.json');
  static File get _pidFile => File('${_stateDir.path}/xray.pid');

  static bool get running => _proc != null;

  static Future<void> start(String config) async {
    await stop();
    if (!File(exe).existsSync()) {
      throw Exception('Не найден файл ядра: $exe');
    }
    await _stateDir.create(recursive: true);
    await _config.writeAsString(config, flush: true);
    await Process.run('chmod', ['600', _config.path]);
    recentOutput.clear();
    final p = await Process.start(exe, ['run', '-c', _config.path],
        environment: {'XRAY_LOCATION_ASSET': coreDir});
    _proc = p;
    await _pidFile.writeAsString('${p.pid}');
    void collect(String line) {
      recentOutput.add(line);
      if (recentOutput.length > 40) recentOutput.removeAt(0);
    }

    p.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(collect);
    p.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(collect);
    unawaited(p.exitCode.then((code) {
      collect('xray завершился, код $code');
      if (identical(_proc, p)) _proc = null;
    }));
  }

  static Future<void> stop() async {
    final p = _proc;
    _proc = null;
    if (p != null) {
      p.kill(ProcessSignal.sigterm);
      try {
        await p.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        p.kill(ProcessSignal.sigkill);
      }
    }
    await killOrphan();
    try {
      if (_config.existsSync()) await _config.delete();
    } catch (_) {}
  }

  /// Ядро, оставшееся после аварийного завершения: завершаем, только если
  /// процесс с сохранённым PID — именно наш xray (по пути к файлу).
  static Future<bool> killOrphan() async {
    try {
      if (!_pidFile.existsSync()) return false;
      final pid = int.tryParse((await _pidFile.readAsString()).trim());
      await _pidFile.delete();
      if (pid == null) return false;
      final link = Link('/proc/$pid/exe');
      if (!link.existsSync()) return false;
      if (link.targetSync() != File(exe).resolveSymbolicLinksSync()) {
        return false;
      }
      Process.killPid(pid, ProcessSignal.sigterm);
      return true;
    } catch (_) {
      return false;
    }
  }
}
