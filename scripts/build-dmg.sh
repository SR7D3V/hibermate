#!/bin/sh
# Builds dist/Hibermate-<version>.dmg (Hibermate.app + an Applications link)
# and its SHA-256 checksum, using only built-in tools (xcodebuild, hdiutil).
#
# Signing is ad-hoc by default (v1 releases are unsigned). Set these to sign
# and notarize instead (never commit credentials):
#   HIBERMATE_SIGN_IDENTITY   e.g. "Developer ID Application: Your Name (TEAMID)"
#   HIBERMATE_TEAM_ID         your Apple Developer Team ID
#   HIBERMATE_NOTARY_PROFILE  a `xcrun notarytool store-credentials` keychain profile
# Optional:
#   HIBERMATE_BUILD_DIR       intermediates (default ~/Library/Caches/hibermate-build)
#   HIBERMATE_DIST_DIR        output folder (default <repo>/dist)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${HIBERMATE_BUILD_DIR:-$HOME/Library/Caches/hibermate-build}/release"
DIST_DIR="${HIBERMATE_DIST_DIR:-$ROOT/dist}"
VERSION="$(sed -n 's/^MARKETING_VERSION *= *//p' "$ROOT/Config/Version.xcconfig" | tr -d '[:space:]')"
[ -n "$VERSION" ] || { echo "Could not read MARKETING_VERSION from Config/Version.xcconfig" >&2; exit 1; }
DMG="$DIST_DIR/Hibermate-$VERSION.dmg"
ARCHIVE="$BUILD_DIR/Hibermate.xcarchive"
STAGING="$BUILD_DIR/dmg-staging"
SIGN_IDENTITY="${HIBERMATE_SIGN_IDENTITY:-}"

echo "==> Hibermate $VERSION"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "==> Archiving (universal, Release)"
if [ -n "$SIGN_IDENTITY" ]; then
    : "${HIBERMATE_TEAM_ID:?HIBERMATE_TEAM_ID is required with HIBERMATE_SIGN_IDENTITY}"
    xcodebuild -project "$ROOT/Hibermate.xcodeproj" -scheme Hibermate -configuration Release \
        -destination "generic/platform=macOS" -archivePath "$ARCHIVE" \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$HIBERMATE_TEAM_ID" \
        OTHER_CODE_SIGN_FLAGS="--timestamp" archive -quiet
    cat > "$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>$HIBERMATE_TEAM_ID</string>
</dict></plist>
EOF
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$BUILD_DIR/export" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -quiet
    APP="$BUILD_DIR/export/Hibermate.app"
else
    # Ad-hoc: the archived app is already signed with "-"; copy it out directly.
    xcodebuild -project "$ROOT/Hibermate.xcodeproj" -scheme Hibermate -configuration Release \
        -destination "generic/platform=macOS" -archivePath "$ARCHIVE" \
        -derivedDataPath "$BUILD_DIR/DerivedData" archive -quiet
    APP="$ARCHIVE/Products/Applications/Hibermate.app"
fi

echo "==> Verifying"
for bin in Hibermate HibermateHelper hibermate-hook; do
    ARCHS="$(lipo -archs "$APP/Contents/MacOS/$bin")"
    case "$ARCHS" in *arm64*x86_64*|*x86_64*arm64*) echo "    $bin: $ARCHS" ;;
        *) echo "$bin is not universal ($ARCHS)" >&2; exit 1 ;; esac
done
[ -f "$APP/Contents/Library/LaunchDaemons/com.sr7d3v.hibermate.helper.plist" ] || { echo "launchd plist missing" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist")" = "true" ] || { echo "LSUIElement not set" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
echo "    signature: $(codesign -dv "$APP" 2>&1 | sed -n 's/^Signature=//p')"

echo "==> Creating DMG"
rm -rf "$STAGING" "$DMG" "$DMG.sha256"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Hibermate.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Hibermate $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" -quiet

if [ -n "$SIGN_IDENTITY" ]; then
    codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
    if [ -n "${HIBERMATE_NOTARY_PROFILE:-}" ]; then
        echo "==> Notarizing"
        xcrun notarytool submit "$DMG" --keychain-profile "$HIBERMATE_NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

(cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "==> Done"
echo "    $DMG"
echo "    SHA-256: $(cut -d' ' -f1 "$DMG.sha256")"
