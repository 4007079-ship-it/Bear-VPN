#!/usr/bin/env bash
# Сквозная проверка Bear VPN на настоящем ядре Xray.
# Поднимает локальные тестовые серверы с одноразовыми ключами, генерирует
# клиентские конфиги тем же кодом, что приложение, и гоняет через каждый
# трафик. Запускается в GitHub Actions (ubuntu), см. .github/workflows/e2e.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="${RUNNER_TEMP:-/tmp}/bear-e2e"
rm -rf "$W" && mkdir -p "$W/bin" "$W/cfg" "$W/logs"
cd "$W"

echo "::group::Ядра"
curl -fsSL -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -qo xray.zip -d bin xray geoip.dat geosite.dat
gh release download -R SagerNet/sing-box -p 'sing-box-*-linux-amd64.tar.gz' -O sb.tgz
tar -xzf sb.tgz --strip-components=1 -C bin --wildcards '*/sing-box'
XRAY="$W/bin/xray"; SB="$W/bin/sing-box"
"$XRAY" version | head -1; "$SB" version | head -1
echo "::endgroup::"

echo "::group::Ключи и сертификаты"
UUID=$("$XRAY" uuid)
KEYS=$("$XRAY" x25519)
PRIV=$(echo "$KEYS" | grep -iE '^private' | awk -F': *' '{print $2}')
PUB=$(echo "$KEYS" | grep -iE '^(public key|password)' | head -1 | awk -F': *' '{print $2}')
PASS=$(openssl rand -hex 12)
[ -n "$PRIV" ] && [ -n "$PUB" ] || { echo "x25519: $KEYS"; exit 1; }
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
  -keyout ca.key -out ca.crt -subj "/CN=Bear Test CA" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout srv.key -out srv.csr -subj "/CN=bear.test" 2>/dev/null
printf "subjectAltName=DNS:bear.test\n" > san.ext
openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 \
  -extfile san.ext -out srv.crt 2>/dev/null
sudo cp ca.crt /usr/local/share/ca-certificates/bear-test.crt
sudo update-ca-certificates >/dev/null
echo "127.0.0.1 bear.test" | sudo tee -a /etc/hosts >/dev/null
# SHA-256 сертификата для pcs= (Xray 26 не поддерживает allowInsecure)
PCS=$(openssl x509 -in srv.crt -outform der | sha256sum | cut -d' ' -f1)
OBFS=$(openssl rand -hex 8)
echo "::endgroup::"

TLS="{\"certificates\":[{\"certificateFile\":\"$W/srv.crt\",\"keyFile\":\"$W/srv.key\"}]}"
REALITY="{\"target\":\"www.microsoft.com:443\",\"serverNames\":[\"www.microsoft.com\"],\"privateKey\":\"$PRIV\",\"shortIds\":[\"\",\"a1b2\"]}"
cat > server.json <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"tag":"reality-tcp","port":20001,"protocol":"vless",
     "settings":{"clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],"decryption":"none"},
     "streamSettings":{"network":"raw","security":"reality","realitySettings":$REALITY}},
    {"tag":"reality-xhttp","port":20002,"protocol":"vless",
     "settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},
     "streamSettings":{"network":"xhttp","xhttpSettings":{"path":"/xh"},"security":"reality","realitySettings":$REALITY}},
    {"tag":"reality-tcp-2","port":20003,"protocol":"vless",
     "settings":{"clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],"decryption":"none"},
     "streamSettings":{"network":"raw","security":"reality","realitySettings":$REALITY}},
    {"tag":"vmess-ws-tls","port":20004,"protocol":"vmess",
     "settings":{"clients":[{"id":"$UUID"}]},
     "streamSettings":{"network":"ws","wsSettings":{"path":"/vm"},"security":"tls","tlsSettings":$TLS}},
    {"tag":"trojan-tls","port":20005,"protocol":"trojan",
     "settings":{"clients":[{"password":"$PASS"}]},
     "streamSettings":{"network":"raw","security":"tls","tlsSettings":$TLS}},
    {"tag":"ss","port":20006,"protocol":"shadowsocks",
     "settings":{"method":"aes-256-gcm","password":"$PASS","network":"tcp,udp"}},
    {"tag":"vless-ws-tls","port":20008,"protocol":"vless",
     "settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},
     "streamSettings":{"network":"ws","wsSettings":{"path":"/vl"},"security":"tls","tlsSettings":$TLS}}
  ],
  "outbounds": [{"protocol":"freedom"}]
}
JSON
cat > hy2.json <<JSON
{"log":{"level":"info"},
 "inbounds":[
  {"type":"hysteria2","listen":"127.0.0.1","listen_port":20007,
   "users":[{"password":"$PASS"}],
   "tls":{"enabled":true,"server_name":"bear.test","certificate_path":"$W/srv.crt","key_path":"$W/srv.key"}},
  {"type":"hysteria2","listen":"127.0.0.1","listen_port":20009,
   "obfs":{"type":"salamander","password":"$OBFS"},
   "users":[{"password":"$PASS"}],
   "tls":{"enabled":true,"server_name":"bear.test","certificate_path":"$W/srv.crt","key_path":"$W/srv.key"}}],
 "outbounds":[{"type":"direct"}]}
JSON
"$XRAY" run -c server.json > logs/server.log 2>&1 &
"$SB" run -c hy2.json > logs/hy2.log 2>&1 &
sleep 2

VMESS=$(printf '{"v":"2","ps":"vmess-ws-tls","add":"127.0.0.1","port":"20004","id":"%s","aid":"0","net":"ws","path":"/vm","host":"bear.test","tls":"tls","sni":"bear.test","scy":"auto","pcs":"%s"}' "$UUID" "$PCS" | base64 -w0)
SSUSER=$(printf 'aes-256-gcm:%s' "$PASS" | base64 -w0)
R="security=reality&sni=www.microsoft.com&pbk=$PUB&sid=a1b2&fp=chrome"
cat > links.txt <<LINKS
vless://$UUID@127.0.0.1:20001?$R&type=tcp&flow=xtls-rprx-vision#reality-tcp
vless://$UUID@127.0.0.1:20002?$R&type=xhttp&path=%2Fxh&mode=auto#reality-xhttp
vless://$UUID@127.0.0.1:20003?$R&type=tcp&flow=xtls-rprx-vision#reality-tcp-2
vmess://$VMESS
trojan://$PASS@127.0.0.1:20005?security=tls&sni=bear.test&type=tcp&pcs=$PCS#trojan-tls
ss://$SSUSER@127.0.0.1:20006#ss
hysteria2://$PASS@127.0.0.1:20007?sni=bear.test&pcs=$PCS#hy2
hysteria2://$PASS@127.0.0.1:20009?sni=bear.test&pcs=$PCS&obfs=salamander&obfs-password=$OBFS#hy2-obfs
hysteria2://$PASS@127.0.0.1:20007?sni=bear.test#info-hy2-system-ca
trojan://$PASS@127.0.0.1:20005?security=tls&sni=bear.test&type=tcp&allowInsecure=1#info-trojan-insecure
vless://$UUID@127.0.0.1:20008?security=tls&sni=bear.test&type=ws&path=%2Fvl&host=bear.test&pcs=$PCS#vless-ws-tls
vless://$UUID@localtest.me:20001?$R&type=tcp&flow=xtls-rprx-vision#reality-domain
vless://$UUID@127.0.0.1:29999?$R&type=tcp&flow=xtls-rprx-vision#dead
vless://$UUID@127.0.0.1:20001?security=reality&sni=www.microsoft.com&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=a1b2&fp=chrome&type=tcp&flow=xtls-rprx-vision#control-wrong-key
LINKS

echo "::group::Генерация конфигов (код приложения)"
(cd "$ROOT/app" && E2E_LINKS="$W/links.txt" E2E_OUT="$W/cfg" \
  flutter test test/e2e_configs_test.dart --reporter expanded)
ls cfg
echo "::endgroup::"

# Проверка одного конфига: поднять клиент, скачать через SOCKS.
PASSED=0; FAILED=0
REPORT="$W/report.md"
printf '| Проверка | Итог | Ответ | Время, с | 5 МБ, Мбит/с |\n|---|---|---|---|---|\n' > "$REPORT"
for f in cfg/*.json; do
  name=$(basename "$f" .json)
  port=$(jq -r '[.inbounds[] | select(.protocol=="socks")][0].port' "$f")
  mkdir -p dbg
  jq '.log = {"loglevel":"debug"}' "$f" > "dbg/$name.json"
  "$XRAY" run -c "dbg/$name.json" > "logs/$name.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do
    (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null && break; sleep 0.2
  done
  code=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 20 \
    --socks5-hostname "127.0.0.1:$port" https://www.gstatic.com/generate_204 || true)
  speed="-"; dl_ok=true
  if [[ "$code" == 204* ]]; then
    dl=$(curl -sS -o /dev/null -w '%{http_code} %{size_download} %{speed_download}' --max-time 40 \
      --socks5-hostname "127.0.0.1:$port" 'https://speed.cloudflare.com/__down?bytes=5000000' 2>>"logs/$name.curl" || true)
    read -r dl_code dl_size dl_bps <<< "${dl:-0 0 0}"
    speed=$(awk -v b="${dl_bps:-0}" 'BEGIN{printf "%.0f", b*8/1000000}')
    [[ "$dl_code" == 200 && "${dl_size:-0}" -ge 5000000 ]] || { dl_ok=false; speed="сбой ($dl_code, ${dl_size:-0} Б)"; }
  fi
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  http=${code%% *}; t=${code#* }
  works=false; [[ "$http" == 204 ]] && $dl_ok && works=true
  expect_fail=false; [[ "$name" == *control-wrong-key* || "$name" == plain__dead ]] && expect_fail=true
  if [[ "$name" == *info-* ]]; then
    if $works; then res="ℹ️ работает"; else res="ℹ️ не работает"; fi
    echo "::group::Лог $name"; { grep -iE "error|fail|warn" "logs/$name.log" | tail -8; } || true; echo "::endgroup::"
  elif [[ $works != "$expect_fail" ]]; then
    res="✅"; PASSED=$((PASSED+1))
    $expect_fail && res="✅ (и должно не работать)"
  else
    res="❌"; FAILED=$((FAILED+1))
    echo "::group::Лог $name"; { grep -vE "\[Debug\].*(dns|DNS)" "logs/$name.log" | tail -25; cat "logs/$name.curl" 2>/dev/null; } || true; echo "::endgroup::"
  fi
  printf '| %s | %s | %s | %s | %s |\n' "$name" "$res" "${http:-нет}" "${t:-}" "$speed" >> "$REPORT"
  echo "$res $name http=$http t=$t speed=${speed}Mbit"
done
printf '\nПройдено: %d, ошибок: %d\n' "$PASSED" "$FAILED" >> "$REPORT"
echo "::group::Лог сервера Hysteria2"; tail -30 logs/hy2.log || true; echo "::endgroup::"
cat "$REPORT"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"
cp -r logs "$ROOT/e2e-logs" 2>/dev/null || true
[ "$FAILED" -eq 0 ]
