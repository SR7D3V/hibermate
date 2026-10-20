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
VOLNAME="Hibermate $VERSION"
RW_DMG="$BUILD_DIR/rw.dmg"
rm -rf "$STAGING" "$DMG" "$DMG.sha256" "$RW_DMG"
mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/Hibermate.app"
ln -s /Applications "$STAGING/Applications"

# Window background with the install steps (drawn with CoreGraphics; no
# third-party tools). Combined into one HiDPI TIFF for Retina displays.
swift "$ROOT/scripts/dmg/render-background.swift" "$BUILD_DIR/background" >/dev/null
tiffutil -cathidpicheck "$BUILD_DIR/background/background.png" "$BUILD_DIR/background/background@2x.png" \
    -out "$STAGING/.background/background.tiff" 2>/dev/null

hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -fs HFS+ -format UDRW -ov "$RW_DMG" -quiet
MOUNT_DIR="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | head -1)"

# Arrange the Finder window: icon positions must match render-background.swift.
# This needs permission for the terminal to control Finder. If it isn't granted
# (or Finder isn't available, e.g. headless CI), the DMG still works, just
# without the custom layout.
if /usr/bin/osascript >/dev/null 2>&1 <<EOF
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 562}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Hibermate.app" of container window to {165, 190}
        set position of item "Applications" of container window to {495, 190}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
then
    echo "    DMG window layout applied"
else
    echo "    warning: couldn't arrange the DMG window (Finder automation not allowed); using the plain layout" >&2
fi
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
sync
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -f "$RW_DMG"

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
