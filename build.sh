#!/bin/bash
# ScreenControl'u .app paketi olarak derler, imzalar ve /Applications'a kurar.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ScreenControl"
BUNDLE_ID="app.pushbrands.screencontrol"
VERSION="1.0.0"
BUILD_DIR=".build/bundle"
APP="$BUILD_DIR/$APP_NAME.app"

# Developer ID varsa onu kullan: imza sabit kalır, böylece her derlemede
# Erişilebilirlik iznini yeniden vermek gerekmez.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')}"
[ -z "$IDENTITY" ] && IDENTITY="-"

echo "▸ Derleniyor (release)…"
swift build -c release --disable-sandbox

echo "▸ Paket hazırlanıyor…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
[ -f "Resources/AppIcon.icns" ] && cp "Resources/AppIcon.icns" "$APP/Contents/Resources/"

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
</dict>
</plist>
PLIST

echo "▸ İmzalanıyor: $IDENTITY"
codesign --force --options runtime --timestamp=none \
         --sign "$IDENTITY" "$APP" 2>&1 | sed 's/^/   /'

echo "▸ Doğrulama:"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier' | sed 's/^/   /'

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
