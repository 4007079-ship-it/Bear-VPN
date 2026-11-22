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

<p align="center">
  <a href="https://github.com/4007079-ship-it/Bear-VPN/releases/latest/download/Bear-VPN-windows-setup.exe"><img src="https://img.shields.io/badge/Windows-%D1%81%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C%20%D1%83%D1%81%D1%82%D0%B0%D0%BD%D0%BE%D0%B2%D1%89%D0%B8%D0%BA-FFC400?style=for-the-badge&logo=windows&logoColor=black&labelColor=0A0A0A" alt="Скачать для Windows"></a>
  <a href="https://github.com/4007079-ship-it/Bear-VPN/releases/latest/download/Bear-VPN-android.apk"><img src="https://img.shields.io/badge/Android-%D1%81%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C%20APK-FFC400?style=for-the-badge&logo=android&logoColor=black&labelColor=0A0A0A" alt="Скачать для Android"></a>
</p>

<p align="center">
  Все версии и описание изменений — на странице <a href="https://github.com/4007079-ship-it/Bear-VPN/releases">Releases</a>.
</p>

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
- IP-адрес выхода, который видят сайты: страна, город, провайдер.
- IPv6 через туннель; выбор IPv4/IPv6 для подключения к серверу.

**Настройки** (по умолчанию выключены)
- Резка первого пакета TLS (fragment).
- Несколько параллельных соединений XHTTP (xmux).
- Несколько серверов сразу с автопереключением: «самый быстрый» или «поровну».

## Скачать

Ссылки ниже всегда ведут на **последнюю версию**:

| Система | Скачать | Как установить |
|---|---|---|
| Windows 10/11 (64 бит) | [Установщик `.exe`](https://github.com/4007079-ship-it/Bear-VPN/releases/latest/download/Bear-VPN-windows-setup.exe) | Запустите и следуйте шагам. Ярлык появится в меню «Пуск». |
| Windows без установки | [Архив `.zip`](https://github.com/4007079-ship-it/Bear-VPN/releases/latest/download/Bear-VPN-windows-x64.zip) | Распакуйте целиком и запустите `BearVPN.exe` (папка `xray` — рядом). |
| Android 6.0+ | [Файл `.apk`](https://github.com/4007079-ship-it/Bear-VPN/releases/latest/download/Bear-VPN-android.apk) | Откройте файл на телефоне, разрешите установку из этого источника. |

Предыдущие версии и контрольные суммы — на странице [Releases](https://github.com/4007079-ship-it/Bear-VPN/releases).
Промежуточные сборки после каждого изменения — в [Actions → app-build](https://github.com/4007079-ship-it/Bear-VPN/actions/workflows/app-build.yml), раздел **Artifacts**.

**Выпустить новую версию:** поднимите `version` в `app/pubspec.yaml`, добавьте заметки `docs/releases/vX.Y.Z.md`
и опубликуйте релиз с тегом `vX.Y.Z` на GitHub (без галочки «Pre-release») — файлы соберутся, приложатся,
а ссылки выше начнут вести на новую версию.

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
