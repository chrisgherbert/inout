#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-}"
DMG_PATH="${2:-}"
VOL_NAME="${3:-In-Out}"
BACKGROUND_NAME="installer-background.png"
WINDOW_LEFT=180
WINDOW_TOP=140
WINDOW_WIDTH=680
WINDOW_HEIGHT=420
APP_ICON_X=170
APP_ICON_Y=248
APPLICATIONS_ICON_X=510
APPLICATIONS_ICON_Y=248

if [[ -z "$APP_PATH" || -z "$DMG_PATH" ]]; then
  echo "Usage: $(basename "$0") /path/to/In-Out.app /path/to/output.dmg [volume-name]"
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH"
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/inout-dmg.XXXXXX")"
STAGING_DIR="$TMP_DIR/staging"
RW_DMG="$TMP_DIR/staging.dmg"
MOUNT_DIR="$TMP_DIR/mount"
BACKGROUND_DIR="$STAGING_DIR/.background"
BACKGROUND_PATH="$BACKGROUND_DIR/$BACKGROUND_NAME"
DEVICE=""
MOUNTED_VOLUME_NAME="$VOL_NAME"

cleanup() {
  set +e
  if [[ -n "$DEVICE" ]]; then
    hdiutil detach "$DEVICE" -quiet >/dev/null 2>&1 || hdiutil detach "$DEVICE" -force -quiet >/dev/null 2>&1
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$BACKGROUND_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

xcrun swift "$ROOT_DIR/scripts/render_dmg_background.swift" "$BACKGROUND_PATH"
chflags hidden "$BACKGROUND_DIR"

rm -f "$RW_DMG"
hdiutil create -quiet -srcfolder "$STAGING_DIR" -volname "$VOL_NAME" -fs HFS+ -format UDRW "$RW_DMG"

ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
DEVICE="$(echo "$ATTACH_OUTPUT" | awk '/Apple_HFS/ {print $1; exit}')"
MOUNT_DIR="$(echo "$ATTACH_OUTPUT" | awk '/Apple_HFS/ {print $NF; exit}')"
if [[ -z "$DEVICE" ]]; then
  echo "Failed to determine mounted DMG device."
  exit 1
fi
if [[ -n "$MOUNT_DIR" ]]; then
  MOUNTED_VOLUME_NAME="$(basename "$MOUNT_DIR")"
fi

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$MOUNTED_VOLUME_NAME"
    open
    delay 0.5
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {$WINDOW_LEFT, $WINDOW_TOP, $(($WINDOW_LEFT + $WINDOW_WIDTH)), $(($WINDOW_TOP + $WINDOW_HEIGHT))}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set text size of theViewOptions to 14
    set background picture of theViewOptions to file ".background:$BACKGROUND_NAME"
    set position of item "$(basename "$APP_PATH")" of container window to {$APP_ICON_X, $APP_ICON_Y}
    set position of item "Applications" of container window to {$APPLICATIONS_ICON_X, $APPLICATIONS_ICON_Y}
    update without registering applications
    delay 1
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$DEVICE" -quiet
DEVICE=""

OUT_BASE="${DMG_PATH%.dmg}"
FINAL_DMG="$OUT_BASE.dmg"
rm -f "$FINAL_DMG"
hdiutil convert "$RW_DMG" -quiet -format UDZO -imagekey zlib-level=9 -o "$OUT_BASE" >/dev/null

echo "Created DMG: $FINAL_DMG"
