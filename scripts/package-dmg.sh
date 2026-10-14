#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${CAPTUREALL_VERSION:-1.0.0}"
DIST="$ROOT/dist"
STAGE="$DIST/dmg-stage"
DMG_NAME="CaptureAll-${VERSION}.dmg"
DMG_PATH="$DIST/$DMG_NAME"

echo "==> Generating AppIcon.icns from logo"
python3 "$ROOT/scripts/generate-icons.py"

echo "==> Building Release CaptureAll"
pkill -9 -f '/CaptureAll.app/Contents/MacOS/CaptureAll' 2>/dev/null || true
pkill -9 -x CaptureAll 2>/dev/null || true
sleep 0.2

xcodebuild \
  -project CaptureAll.xcodeproj \
  -scheme CaptureAll \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' \
  DEVELOPMENT_TEAM=C58UNCGQS7 \
  CODE_SIGN_IDENTITY="Apple Development" \
  ENABLE_DEBUG_DYLIB=NO \
  build

BUILT="$ROOT/build/DerivedData/Build/Products/Release/CaptureAll.app"
if [[ ! -d "$BUILT" ]]; then
  echo "ERROR: missing $BUILT"
  exit 1
fi

echo "==> Staging app"
mkdir -p "$DIST"
rm -rf "$DIST/CaptureAll.app" "$STAGE" "$DMG_PATH"
cp -R "$BUILT" "$DIST/CaptureAll.app"
xattr -cr "$DIST/CaptureAll.app" || true

# Always ship the generated .icns so Finder/DMG show the logo.
RES="$DIST/CaptureAll.app/Contents/Resources"
mkdir -p "$RES"
cp "$ROOT/CaptureAll/Resources/AppIcon.icns" "$RES/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon' "$DIST/CaptureAll.app/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$DIST/CaptureAll.app/Contents/Info.plist"
# Do not set CFBundleIconName — Assets.car may encode the B&W logo as
# monochrome and Finder then drops the black fill (white sides).
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$DIST/CaptureAll.app/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$DIST/CaptureAll.app" >/dev/null

echo "==> App Resources:"
ls -lh "$RES/AppIcon.icns" "$RES/Assets.car" 2>/dev/null || ls -la "$RES"

mkdir -p "$STAGE"
cp -R "$DIST/CaptureAll.app" "$STAGE/CaptureAll.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG_PATH"
hdiutil create \
  -volname "CaptureAll" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGE"

echo ""
echo "App:  $DIST/CaptureAll.app"
echo "DMG:  $DMG_PATH"
ls -lh "$DMG_PATH"
