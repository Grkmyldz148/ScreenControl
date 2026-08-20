#!/bin/bash
# ScreenControl'u .app paketi olarak derler, imzalar ve /Applications'a kurar.
#
#   ./build.sh            → .build/bundle/ScreenControl.app üretir
#   ./build.sh install    → üretir ve /Applications'a kurar
#
# Dağıtılabilir (notarize edilmiş) sürüm için release.sh'yi kullan.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ScreenControl"
BUNDLE_ID="app.pushbrands.screencontrol"
VERSION="${VERSION:-$(cat VERSION)}"
BUILD_DIR=".build/bundle"
APP="$BUILD_DIR/$APP_NAME.app"

# Sparkle'ın güncelleme beslemesi ve imza doğrulama anahtarı.
# Özel anahtar login keychain'de ("Private key for signing Sparkle updates");
# repoda sadece açık anahtar bulunur.
FEED_URL="https://raw.githubusercontent.com/Grkmyldz148/ScreenControl/main/appcast.xml"
PUBLIC_ED_KEY="DPfB2ibXtUxBqrHb3FBYwRpi66kARex0XPps4SB+cs0="

# Developer ID varsa onu kullan: imza sabit kalır, böylece her derlemede
# Erişilebilirlik iznini yeniden vermek gerekmez.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')}"
[ -z "$IDENTITY" ] && IDENTITY="-"

# Ad-hoc imzada güvenli zaman damgası istenmez (ve gereksiz yere yavaştır);
# Developer ID ile imzalarken ise ZORUNLUDUR — damgasız imza notarize edilemez.
TIMESTAMP_FLAG="--timestamp"
[ "$IDENTITY" = "-" ] && TIMESTAMP_FLAG="--timestamp=none"

echo "▸ Derleniyor (release)…"
swift build -c release --disable-sandbox

SPARKLE_FRAMEWORK="$(find .build/artifacts/sparkle -type d -name "Sparkle.framework" -path "*macos*" | head -1)"
[ -z "$SPARKLE_FRAMEWORK" ] && { echo "✗ Sparkle.framework bulunamadı; 'swift package resolve' çalıştır."; exit 1; }

echo "▸ Paket hazırlanıyor…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
[ -f "Resources/AppIcon.icns" ] && cp "Resources/AppIcon.icns" "$APP/Contents/Resources/"

# -R sembolik bağları koruyarak kopyalar; framework'ün Versions/Current yapısı buna bağlı.
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
# Başlıklar çalışma zamanında gereksiz; paketi küçültür ve imzayı sadeleştirir.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Headers" \
       "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/PrivateHeaders" \
       "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Modules" \
       "$APP/Contents/Frameworks/Sparkle.framework/Headers" \
       "$APP/Contents/Frameworks/Sparkle.framework/PrivateHeaders" \
       "$APP/Contents/Frameworks/Sparkle.framework/Modules"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Menü çubuğunda yaşayan uygulama: Dock ikonu ve uygulama menüsü yok. -->
    <key>LSUIElement</key><true/>
    <!-- Sparkle: otomatik güncelleme -->
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$PUBLIC_ED_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

# İmzalama içeriden dışarıya yapılmalı: en derindeki çalıştırılabilirden başlayıp
# framework'e, en son da .app'e. Sparkle'ın SPM dağıtımı ad-hoc imzalı geliyor;
# notarization ad-hoc iç bileşenleri reddettiği için hepsini yeniden imzalıyoruz.
echo "▸ İmzalanıyor: $IDENTITY"
SPARKLE_IN_APP="$APP/Contents/Frameworks/Sparkle.framework"
for nested in \
    "$SPARKLE_IN_APP/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE_IN_APP/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE_IN_APP/Versions/B/Autoupdate" \
    "$SPARKLE_IN_APP/Versions/B/Updater.app" \
    "$SPARKLE_IN_APP/Versions/B" ; do
    [ -e "$nested" ] || continue
    codesign --force --options runtime $TIMESTAMP_FLAG --sign "$IDENTITY" "$nested"
done

codesign --force --options runtime $TIMESTAMP_FLAG --sign "$IDENTITY" "$APP"

echo "▸ Doğrulama:"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier' | sed 's/^/   /'
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/   /'

if [ "${1:-}" = "install" ]; then
    echo "▸ /Applications'a kuruluyor…"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "✓ Kuruldu: /Applications/$APP_NAME.app"
else
    echo "✓ Hazır: $APP"
fi
