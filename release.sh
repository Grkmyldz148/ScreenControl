#!/bin/bash
# ScreenControl'un dağıtılabilir sürümünü üretir:
# derler → notarize eder → ZIP + DMG paketler → appcast'i günceller → GitHub release açar.
#
#   ./release.sh 1.1.0            → tam yayın
#   ./release.sh 1.1.0 --dry-run  → her şeyi üret, GitHub'a hiçbir şey gönderme
#
# Gereksinimler:
#   • "Developer ID Application" sertifikası (imzalama)
#   • notarytool keychain profili — bir kez:
#       xcrun notarytool store-credentials "ScreenControl" \
#         --apple-id "<apple-id>" --team-id "R9WY247JU6" --password "<app-specific-password>"
#   • Sparkle EdDSA özel anahtarı login keychain'de (generate_keys ile üretilir)
#   • gh CLI, yetkilendirilmiş
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ScreenControl"
REPO="Grkmyldz148/ScreenControl"
TEAM_ID="R9WY247JU6"
NOTARY_PROFILE="${NOTARY_PROFILE:-ScreenControl}"

VERSION="${1:-}"
DRY_RUN=false
[ "${2:-}" = "--dry-run" ] && DRY_RUN=true

[ -z "$VERSION" ] && { echo "Kullanım: ./release.sh <sürüm> [--dry-run]   (örn. ./release.sh 1.1.0)"; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ Sürüm x.y.z biçiminde olmalı: $VERSION"; exit 1; }

DIST="dist"
ARCHIVES="$DIST/archives"          # Sparkle'ın besleme geçmişi burada birikir (git dışı)
APP="$DIST/$APP_NAME.app"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

# ── Ön koşullar ───────────────────────────────────────────────────────────────

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

step "Ön koşullar denetleniyor"

security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" \
  || fail "Developer ID Application sertifikası bulunamadı. Apple Developer Program üyeliği gerekiyor."

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || fail \
"notarytool profili '$NOTARY_PROFILE' bulunamadı. Bir kez şunu çalıştır:

  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
    --apple-id \"<apple-id-eposta>\" \\
    --team-id \"$TEAM_ID\" \\
    --password \"<app-specific-password>\"

App-specific password: https://account.apple.com → Oturum Açma ve Güvenlik → Uygulamaya Özel Parolalar"

command -v gh >/dev/null || fail "gh CLI kurulu değil (brew install gh)."
$DRY_RUN || gh auth status >/dev/null 2>&1 || fail "gh yetkilendirilmemiş (gh auth login)."

[ -x "$SPARKLE_BIN/generate_appcast" ] || fail "Sparkle araçları yok; 'swift package resolve' çalıştır."
"$SPARKLE_BIN/generate_keys" -p >/dev/null 2>&1 \
  || fail "Sparkle EdDSA özel anahtarı keychain'de yok; '$SPARKLE_BIN/generate_keys' çalıştır."

if ! $DRY_RUN; then
    [ -z "$(git status --porcelain)" ] || fail "Çalışma ağacı temiz değil; önce commit et."
    git rev-parse --verify "refs/tags/v$VERSION" >/dev/null 2>&1 \
      && fail "v$VERSION etiketi zaten var."
    gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1 \
      && fail "v$VERSION release'i zaten yayında."
    # Etiket, uzak depoda bulunmayan bir commit'e konamaz.
    git fetch --quiet origin
    git merge-base --is-ancestor HEAD "origin/$(git rev-parse --abbrev-ref HEAD)" 2>/dev/null \
      || fail "HEAD origin'e gönderilmemiş; önce 'git push' yap."
fi

echo "   Sürüm      : $VERSION"
echo "   Depo       : $REPO"
echo "   Kuru çalışma: $DRY_RUN"

# ── Derle ─────────────────────────────────────────────────────────────────────

step "Derleniyor ve imzalanıyor"
echo "$VERSION" > VERSION
VERSION="$VERSION" ./build.sh >/dev/null
rm -rf "$APP"; mkdir -p "$DIST" "$ARCHIVES"
cp -R ".build/bundle/$APP_NAME.app" "$APP"

codesign --verify --deep --strict "$APP" || fail "İmza doğrulaması başarısız."
# Zaman damgası olmayan imza notarize edilemez; sessizce ad-hoc'a düşmediğimizi doğrula.
codesign -dvv "$APP" 2>&1 | grep -q "Timestamp=" || fail "İmzada güvenli zaman damgası yok."
echo "   $(codesign -dv "$APP" 2>&1 | grep 'Authority=Developer ID' | head -1)"

# ── Notarize et ───────────────────────────────────────────────────────────────

step "Notarization'a gönderiliyor (birkaç dakika sürebilir)"
NOTARIZE_ZIP="$DIST/.notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
  || fail "Notarization başarısız. Ayrıntı: xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
rm -f "$NOTARIZE_ZIP"

step "Bilet uygulamaya işleniyor (staple)"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
# Gatekeeper'ın gerçekte ne diyeceğini burada görüyoruz: "accepted" olmalı.
spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/   /'

# ── Paketle ───────────────────────────────────────────────────────────────────

step "ZIP hazırlanıyor"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "   $ZIP ($(du -h "$ZIP" | cut -f1))"

step "DMG hazırlanıyor"
STAGING="$DIST/.dmg-staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # sürükle-bırak kurulumu
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" \
  -fs HFS+ -format UDZO -ov -quiet "$DMG"
rm -rf "$STAGING"

# DMG'nin kendisi de imzalanıp notarize edilmeli, yoksa indirilen dosya
# açılırken karantina uyarısı verir.
DMG_IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"
codesign --force --timestamp --sign "$DMG_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
  || fail "DMG notarization başarısız."
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "   $DMG ($(du -h "$DMG" | cut -f1))"

# ── Appcast ───────────────────────────────────────────────────────────────────

step "Appcast üretiliyor"
# Var olan besleme arşiv dizinine kopyalanıyor: generate_appcast eski kayıtları
# koruyup yenisini ekliyor, eski sürümlerin indirme adresleri bozulmuyor.
[ -f appcast.xml ] && cp appcast.xml "$ARCHIVES/appcast.xml"
cp "$ZIP" "$ARCHIVES/"
# Sürüm notları: Notes/<sürüm>.md varsa Sparkle penceresinde gösterilir.
[ -f "Notes/$VERSION.md" ] && cp "Notes/$VERSION.md" "$ARCHIVES/$APP_NAME-$VERSION.md"

"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" \
  --full-release-notes-url "https://github.com/$REPO/releases" \
  --embed-release-notes \
  "$ARCHIVES"

cp "$ARCHIVES/appcast.xml" appcast.xml
echo "   appcast.xml güncellendi:"
grep -E 'sparkle:(shortVersionString|version)=|<enclosure' appcast.xml | head -6 | sed 's/^/   /'

# ── Yayınla ───────────────────────────────────────────────────────────────────

if $DRY_RUN; then
    step "Kuru çalışma — GitHub'a hiçbir şey gönderilmedi"
    echo "   Üretilenler: $ZIP"
    echo "                $DMG"
    echo "                appcast.xml"
    exit 0
fi

step "GitHub release oluşturuluyor"
NOTES_ARG=(--generate-notes)
[ -f "Notes/$VERSION.md" ] && NOTES_ARG=(--notes-file "Notes/$VERSION.md")

gh release create "v$VERSION" -R "$REPO" \
  --title "$APP_NAME $VERSION" \
  --target "$(git rev-parse HEAD)" \
  "${NOTES_ARG[@]}" \
  "$DMG" "$ZIP"

step "Appcast depoya işleniyor"
# Bu adım kritik: kurulu uygulamalar güncellemeyi ancak main'deki appcast.xml
# üzerinden görüyor.
git add appcast.xml VERSION
git commit -m "Release v$VERSION"
git push origin HEAD

printf '\n\033[32m✓ Yayınlandı: https://github.com/%s/releases/tag/v%s\033[0m\n' "$REPO" "$VERSION"
echo "  Kurulu sürümler güncellemeyi 24 saat içinde (ya da menüden elle denetleyince) görecek."
