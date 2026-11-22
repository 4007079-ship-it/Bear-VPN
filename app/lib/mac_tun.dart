import 'dart:io';

/// Режим VPN на macOS без подписи Apple: виртуальный адаптер utun через
/// tun2socks, который отправляет весь трафик Mac в SOCKS-вход ядра Xray.
///
/// Нужны права администратора — macOS спрашивает пароль при подключении.
/// Сценарий, запущенный от администратора, сам следит за Bear: при
/// «Отключить», закрытии или падении приложения он возвращает маршруты
/// и DNS как было, поэтому повторный пароль не нужен.
class MacTun {
  MacTun._();

  static String get _home => Platform.environment['HOME'] ?? '/tmp';
  static Directory get _state =>
      Directory('$_home/Library/Application Support/BearVPN/tun');

  /// Contents/MacOS/Bear VPN → Contents/Resources/tun
  static String get _resDir =>
      '${File(Platform.resolvedExecutable).parent.parent.path}/Resources/tun';

  static File get _stop => File('${_state.path}/stop');
  static File get _running => File('${_state.path}/running');

  static bool get active => _running.existsSync();

  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// Включить адаптер. [serverHosts] — адреса серверов: им нужен маршрут
  /// мимо адаптера, иначе соединение ядра с сервером зациклится.
  /// Возвращает текст ошибки или null.
  static Future<String?> up({
    required int socksPort,
    required List<String> serverHosts,
  }) async {
    final ips4 = <String>{}, ips6 = <String>{};
    for (final h in serverHosts) {
      try {
        for (final a in await InternetAddress.lookup(h)) {
          (a.type == InternetAddressType.IPv4 ? ips4 : ips6).add(a.address);
        }
      } catch (_) {}
    }
    if (ips4.isEmpty && ips6.isEmpty) {
      return 'Не удалось узнать IP-адрес сервера';
    }
    await _state.create(recursive: true);
    if (_stop.existsSync()) await _stop.delete();
    final script = File('${_state.path}/up.sh');
    await script.writeAsString(_upScript(
      state: _state.path,
      resDir: _resDir,
      socksPort: socksPort,
      ips4: ips4.toList(),
      ips6: ips6.toList(),
      appPid: pid,
    ));
    final cmd = '/bin/sh ${_q(script.path)}';
    final esc = cmd.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    final r = await Process.run('/usr/bin/osascript', [
      '-e',
      'do shell script "$esc" with prompt "Bear VPN включает режим VPN" '
          'with administrator privileges',
    ]);
    if (r.exitCode != 0) {
      final err = (r.stderr as String).trim();
      if (err.contains('-128') || err.toLowerCase().contains('cancel')) {
        return 'Режим VPN не включён: пароль администратора не введён';
      }
      return 'Режим VPN не включился: $err';
    }
    return null;
  }

  /// Выключить: сценарий-сторож увидит файл и всё вернёт сам.
  static Future<void> down() async {
    if (!active) return;
    try {
      await _state.create(recursive: true);
      await _stop.writeAsString('1');
    } catch (_) {}
    for (var i = 0; i < 50 && active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  static String _upScript({
    required String state,
    required String resDir,
    required int socksPort,
    required List<String> ips4,
    required List<String> ips6,
    required int appPid,
  }) =>
      '''
#!/bin/sh
STATE=${_q(state)}
RES=${_q(resDir)}
STOP="\$STATE/stop"; RUN="\$STATE/running"; SAVED="\$STATE/dns.saved"
TUN=utun225
IPS4="${ips4.join(' ')}"
IPS6="${ips6.join(' ')}"
rm -f "\$STOP"
case "\$(uname -m)" in
  arm64) T2S="\$RES/tun2socks-darwin-arm64" ;;
  *) T2S="\$RES/tun2socks-darwin-amd64" ;;
esac
[ -x "\$T2S" ] || chmod +x "\$T2S" 2>/dev/null
xattr -d com.apple.quarantine "\$T2S" 2>/dev/null
[ -x "\$T2S" ] || { echo "нет файла tun2socks" >&2; exit 1; }

GW=\$(route -n get default 2>/dev/null | awk '/gateway:/{print \$2; exit}')
IF4=\$(route -n get default 2>/dev/null | awk '/interface:/{print \$2; exit}')
GW6=\$(route -n get -inet6 default 2>/dev/null | awk '/gateway:/{print \$2; exit}')
[ -n "\$GW" ] || { echo "нет подключения к интернету (шлюз не найден)" >&2; exit 1; }

"\$T2S" -device "\$TUN" -proxy socks5://127.0.0.1:$socksPort -loglevel warning > "\$STATE/tun2socks.log" 2>&1 &
T2PID=\$!
i=0
while ! ifconfig "\$TUN" >/dev/null 2>&1; do
  i=\$((i+1))
  if [ \$i -gt 50 ] || ! kill -0 \$T2PID 2>/dev/null; then
    kill \$T2PID 2>/dev/null
    echo "виртуальный адаптер не создан: \$(tail -3 "\$STATE/tun2socks.log")" >&2
    exit 1
  fi
  sleep 0.1
done
ifconfig "\$TUN" 198.18.0.1 198.18.0.1 netmask 255.255.255.255 up
ifconfig "\$TUN" inet6 fd00:bea4::1 prefixlen 128 2>/dev/null

for ip in \$IPS4; do route -n add -host "\$ip" "\$GW" >/dev/null 2>&1; done
if [ -n "\$GW6" ]; then
  for ip in \$IPS6; do route -n add -inet6 -host "\$ip" "\$GW6" >/dev/null 2>&1; done
fi
route -n add -net 0.0.0.0/1 198.18.0.1 >/dev/null 2>&1
route -n add -net 128.0.0.0/1 198.18.0.1 >/dev/null 2>&1
route -n add -inet6 -net ::/1 -interface "\$TUN" >/dev/null 2>&1
route -n add -inet6 -net 8000::/1 -interface "\$TUN" >/dev/null 2>&1

# DNS через туннель: иначе запросы уходят к провайдеру и подменяются
if [ ! -f "\$SAVED" ]; then
  networksetup -listallnetworkservices | tail -n +2 | grep -v '^\\*' | while IFS= read -r svc; do
    cur=\$(networksetup -getdnsservers "\$svc" | tr '\\n' ' ')
    case "\$cur" in *"aren't any"*|*"There aren"*) cur=empty ;; esac
    printf '%s\\t%s\\n' "\$svc" "\$cur" >> "\$SAVED"
  done
fi
networksetup -listallnetworkservices | tail -n +2 | grep -v '^\\*' | while IFS= read -r svc; do
  networksetup -setdnsservers "\$svc" 1.1.1.1 8.8.8.8
done
dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null
echo \$T2PID > "\$RUN"

cleanup() {
  kill \$T2PID 2>/dev/null
  route -n delete -net 0.0.0.0/1 >/dev/null 2>&1
  route -n delete -net 128.0.0.0/1 >/dev/null 2>&1
  route -n delete -inet6 -net ::/1 >/dev/null 2>&1
  route -n delete -inet6 -net 8000::/1 >/dev/null 2>&1
  for ip in \$IPS4; do route -n delete -host "\$ip" >/dev/null 2>&1; done
  for ip in \$IPS6; do route -n delete -inet6 -host "\$ip" >/dev/null 2>&1; done
  if [ -f "\$SAVED" ]; then
    while IFS="\$(printf '\\t')" read -r svc cur; do
      networksetup -setdnsservers "\$svc" \$cur
    done < "\$SAVED"
    rm -f "\$SAVED"
  fi
  dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null
  rm -f "\$RUN" "\$STOP"
}

# Сторож: отключение, закрытие или падение Bear — вернуть всё как было
(
  trap '' HUP
  while kill -0 $appPid 2>/dev/null && [ ! -f "\$STOP" ] && kill -0 \$T2PID 2>/dev/null; do
    sleep 1
  done
  cleanup
) </dev/null >/dev/null 2>&1 &
exit 0
''';
}
