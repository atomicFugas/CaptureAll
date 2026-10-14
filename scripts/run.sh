#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Always stop every running CaptureAll agent first (duplicates hide the menu item).
pkill -9 -f '/CaptureAll.app/Contents/MacOS/CaptureAll' 2>/dev/null || true
pkill -9 -x CaptureAll 2>/dev/null || true
sleep 0.3

xcodebuild \
  -project CaptureAll.xcodeproj \
  -scheme CaptureAll \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' \
  DEVELOPMENT_TEAM=C58UNCGQS7 \
  CODE_SIGN_IDENTITY="Apple Development" \
  ENABLE_DEBUG_DYLIB=NO \
  build

BUILT="$ROOT/build/DerivedData/Build/Products/Debug/CaptureAll.app"
mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/CaptureAll.app"
cp -R "$BUILT" "$ROOT/dist/CaptureAll.app"
xattr -cr "$ROOT/dist/CaptureAll.app" || true

# Install a real .app under /Applications so LaunchServices / menu bar extras work.
# Running Contents/MacOS/CaptureAll directly (or only from DerivedData) often yields
# a status item that never paints in the system menu bar.
APP="/Applications/CaptureAll.app"
rm -rf "$APP"
cp -R "$ROOT/dist/CaptureAll.app" "$APP"
xattr -cr "$APP" || true

# Reset guides for both old and new bundle IDs (mb2 clears StatusKit blocklist identity).
for bid in app.captureall.CaptureAll app.captureall.CaptureAll.mb2; do
  defaults delete "$bid" didShowMenuBarGuide 2>/dev/null || true
  defaults delete "$bid" didShowMenuBarBlockedGuide 2>/dev/null || true
done

# MUST use `open` on the .app — never exec the raw binary.
open "$APP"

sleep 0.8
if pgrep -x CaptureAll >/dev/null; then
  echo "Launched: $APP (pid $(pgrep -x CaptureAll | tr '\n' ' '))"
else
  echo "ERROR: CaptureAll did not stay running after open."
  exit 1
fi

echo ""
echo "Bundle ID is now app.captureall.CaptureAll.mb2 (fresh StatusKit identity)."
echo "If the camera icon is missing: System Settings → Menu Bar → allow CaptureAll."
echo "Hotkey: ⌘⇧A. Prefer this script or double-click /Applications/CaptureAll.app."

