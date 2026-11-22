#!/usr/bin/env bash
# Упаковка Linux-сборки Bear VPN: .tar.gz и .deb.
# Запуск из app/ после `flutter build linux --release` и копирования ядра.
set -euo pipefail
VER=$(grep -E '^version:' pubspec.yaml | sed -E 's/version:\s*([0-9.]+).*/\1/')
B=build/linux/x64/release/bundle
OUT=build/dist
rm -rf "$OUT" && mkdir -p "$OUT"

convert branding/bear_icon_1024.png -resize 256x256 "$B/bear-vpn.png"

# Архив без установки
cp -r "$B" "$OUT/Bear-VPN"
tar -C "$OUT" -czf "$OUT/Bear-VPN-${VER}-linux-x64.tar.gz" Bear-VPN
rm -rf "$OUT/Bear-VPN"

# Пакет .deb (Ubuntu 22.04+, Debian 12+, Mint 21+)
P=$(mktemp -d)
mkdir -p "$P/DEBIAN" "$P/opt/bear-vpn" "$P/usr/bin" "$P/usr/share/applications"
cp -r "$B/." "$P/opt/bear-vpn/"
ln -s /opt/bear-vpn/bear-vpn "$P/usr/bin/bear-vpn"
for s in 64 128 256 512; do
  d="$P/usr/share/icons/hicolor/${s}x${s}/apps"; mkdir -p "$d"
  convert branding/bear_icon_1024.png -resize ${s}x${s} "$d/bear-vpn.png"
done
cat > "$P/usr/share/applications/bear-vpn.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Bear VPN
Comment=Клиент VPN на ядре Xray
Exec=/opt/bear-vpn/bear-vpn
Icon=bear-vpn
Terminal=false
Categories=Network;
StartupWMClass=com.smv.smv_vpn
DESK
SIZE=$(du -sk "$P/opt" | cut -f1)
cat > "$P/DEBIAN/control" <<CTRL
Package: bear-vpn
Version: ${VER}
Architecture: amd64
Maintainer: SMV <4007079@gmail.com>
Installed-Size: ${SIZE}
Depends: libgtk-3-0 | libgtk-3-0t64, libsecret-1-0, libjsoncpp25, libayatana-appindicator3-1
Section: net
Priority: optional
Homepage: https://github.com/4007079-ship-it/Bear-VPN
Description: Bear VPN — клиент VPN на ядре Xray
 Добавление серверов по ссылке, QR-коду, файлу или подписке.
 Режимы «Прокси» и «Системный прокси».
CTRL
cat > "$P/DEBIAN/postrm" <<'POST'
#!/bin/sh
# Ядро могло остаться после аварийного завершения
pkill -f '^/opt/bear-vpn/xray/xray ' 2>/dev/null || true
exit 0
POST
chmod 755 "$P/DEBIAN/postrm"
dpkg-deb --root-owner-group --build "$P" "$OUT/Bear-VPN-${VER}-linux-amd64.deb" >/dev/null
rm -rf "$P"
ls -la "$OUT"
