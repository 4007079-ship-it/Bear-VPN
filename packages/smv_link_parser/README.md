# smv_link_parser

SMV.LinkParser — офлайн-импорт узлов для SMV-VPN. Чистый Dart, подключается в Flutter-приложение как path-зависимость. Требования описаны в [docs/node-import.md](../../docs/node-import.md).

## Что разбирает

| Вход | Пример |
|---|---|
| VLESS (Reality, tcp/ws/grpc/httpupgrade/xhttp) | `vless://uuid@host:443?security=reality&pbk=…&sid=…&sni=…&fp=chrome#name` |
| VMess | `vmess://BASE64(JSON)` или `vmess://uuid@host:port?…` |
| Hysteria2 | `hysteria2://auth@host:443,20000-30000/?sni=…&obfs=salamander…`, алиас `hy2://` |
| TUIC v5 | `tuic://uuid:password@host:443?congestion_control=bbr&alpn=h3` |
| Trojan | `trojan://password@host:443?sni=…&type=ws…` |
| Shadowsocks | SIP002 (base64url или открытый 2022-формат), legacy `ss://BASE64(…)` |
| SOCKS5 / HTTP | `socks://user:pass@host:1080`, `http://user:pass@host:3128` |
| AmneziaVPN | ключ `vpn://…` (контейнеры amnezia-awg/awg2, amnezia-wireguard, amnezia-xray) и его JSON |
| AmneziaWG / WireGuard | `.conf` (AWG 1.0/1.5/2.0: Jc, Jmin, Jmax, S1–S4, H1–H4 и диапазоны, I1–I5; ключи AWG 3.x сохраняются) |
| Base64-подписка | стандартный и URL-safe base64, с padding и без |
| Список ссылок | через `\n`, `\r\n`, пробел или запятую |
| sing-box JSON | `outbounds` (служебные direct/selector/urltest пропускаются) |
| Xray / V2Ray JSON | `outbounds` (freedom/blackhole пропускаются) |
| Clash / Mihomo YAML | секция `proxies` |

## Использование

```dart
import 'package:smv_link_parser/smv_link_parser.dart';

const parser = LinkParser();
final r = parser.parse(text, sourceType: SourceType.qr);

if (r.isFailure) showError(r.issues.first.message);
for (final node in r.nodes) {
  final issues = validateNode(node);       // ошибки блокируют «Добавить»
  final blocked = issues.any((i) => i.isError);
}
for (final url in r.subscriptionUrls) {
  // предложить «Добавить подписку» — загрузка вне парсера
}

final qrText = shareUri(node);             // для «Поделиться / QR»
// AmneziaWG/WireGuard: QR — текст .conf (или исходный vpn://-ключ)
if (containsSecrets(node)) warn('QR содержит ключи доступа');
```

## Тесты

```sh
cd packages/smv_link_parser
dart pub get
dart test
```

## Ограничения

- `dart:io` (zlib для ключей `vpn://`) — пакет работает на Android, iOS, Windows, macOS, Linux, но не в Flutter Web.
- Ключи Amnezia Premium/Free (`api_key`) не поддерживаются: их конфиг выдаётся серверами Amnezia по сети.
- Контейнеры OpenVPN, Cloak, Shadowsocks (без XRay), IKEv2 из ключей Amnezia помечаются как неподдерживаемые.
