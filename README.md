<p align="center">
  <img src="app/branding/bear_icon_1024.png" width="128" alt="Bear VPN">
</p>

<h1 align="center">Bear VPN</h1>

<p align="center">
  Клиент VPN для Android и Windows на ядре Xray.<br>
  Добавление серверов по ссылке, QR-коду, файлу или подписке — в одно касание.
</p>

<p align="center">
  <a href="https://github.com/4007079-ship-it/Bear-VPN/actions/workflows/app-build.yml"><img src="https://github.com/4007079-ship-it/Bear-VPN/actions/workflows/app-build.yml/badge.svg?branch=main" alt="Сборка"></a>
  <a href="https://github.com/4007079-ship-it/Bear-VPN/actions/workflows/link-parser.yml"><img src="https://github.com/4007079-ship-it/Bear-VPN/actions/workflows/link-parser.yml/badge.svg?branch=main" alt="Парсер"></a>
</p>

> Тестовая версия. Скачать — на странице [Releases](https://github.com/4007079-ship-it/Bear-VPN/releases).

## Возможности

**Добавление серверов**
- Ссылки: `vless://`, `vmess://`, `trojan://`, `ss://`, `hysteria2://`, `tuic://`, `socks://`, `http://`, `wireguard://`, ключи AmneziaVPN `vpn://`.
- Конфиги: sing-box JSON, Clash YAML, Xray JSON, base64-подписки, WireGuard / AmneziaWG `.conf`.
- Источники: буфер обмена, ручной ввод, файл, камера (QR), QR с картинки или фото.
- Подписки по ссылке: автообновление, трафик и срок действия из заголовков панели (3x-ui, Marzban, Remnawave и др.).
- Проверка перед добавлением: предупреждения о небезопасных и неполных настройках, удаление дублей.
- Ключи и ссылки подписок хранятся в защищённом хранилище системы.

**Подключение**
- Протоколы: VLESS (Reality, XHTTP, WS, gRPC…), VMess, Trojan, Shadowsocks, Hysteria2, SOCKS.
- Режимы: «Прокси» (только локальный порт), «Системный прокси» (Windows), «VPN» (весь трафик; на Windows — с правами администратора).
- При отключении и закрытии программы прокси Windows возвращается как было.
- Задержка (пинг), скорость и объём трафика, значок состояния в трее Windows.

**Настройки** (по умолчанию выключены)
- Резка первого пакета TLS (fragment).
- Несколько параллельных соединений XHTTP (xmux).
- Несколько серверов сразу с автопереключением: «самый быстрый» или «поровну».

## Скачать

Последняя версия — на странице [Releases](https://github.com/4007079-ship-it/Bear-VPN/releases):
- `Bear-VPN-<версия>-android.apk` — Android 6.0+;
- `Bear-VPN-<версия>-windows-setup.exe` — установщик для Windows 10/11 (64 бит);
- `Bear-VPN-<версия>-windows-x64.zip` — Windows без установки: распакуйте целиком и запустите `BearVPN.exe`,
  папка `xray` должна лежать рядом.

Промежуточные сборки после каждого изменения — в [Actions → app-build](https://github.com/4007079-ship-it/Bear-VPN/actions/workflows/app-build.yml),
раздел **Artifacts** у последнего успешного запуска.

**Новая версия:** поднимите `version` в `app/pubspec.yaml`, добавьте заметки `docs/releases/vX.Y.Z.md` и опубликуйте
релиз с тегом `vX.Y.Z` на GitHub — файлы соберутся и приложатся сами.

## Устройство проекта

```
app/                      приложение на Flutter (Android, Windows)
  lib/
    screens/              экраны: главная, серверы, настройки, логи
    vpn_controller.dart   запуск ядра, режимы, статистика
    core_tweaks.dart      fragment, xmux, балансировщик — правки конфига Xray
    subscription.dart     загрузка подписок
    nodes_store.dart      хранение серверов и подписок
    windows_proxy_guard.dart  возврат прокси Windows
  branding/               логотип и значки
  installer/              установщик Windows (Inno Setup)
packages/smv_link_parser/ разбор ссылок, конфигов и подписок (чистый Dart, с тестами)
docs/node-import.md       техническое задание на добавление серверов
.github/workflows/        сборка APK и Windows, тесты
```

Ядро: [Xray-core](https://github.com/XTLS/Xray-core) через плагин [flutter_vless](https://pub.dev/packages/flutter_vless).
Папки `android/` и `windows/` создаются при сборке командой `flutter create` — настройки названия, значков и
манифеста задаются в [app-build.yml](.github/workflows/app-build.yml).

## Сборка у себя

Нужен Flutter (stable), для Android — JDK 21.

```bash
cd app
flutter create --platforms=android,windows --org com.smv --project-name smv_vpn .
flutter pub get
flutter test
flutter build apk --release      # Android
flutter build windows --release  # Windows; затем положите Xray в build/.../Release/xray/
```

Тесты парсера:

```bash
cd packages/smv_link_parser
dart pub get && dart test
```

## Планы

- AmneziaWG и WireGuard — подключение (ключи уже разбираются).
- Перетаскивание файлов и QR в окно на Windows.
- Суммирование каналов.

## Разработчик

SMV. Частный проект, все права защищены.
