#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="In-Out.app"
APP_PATH="$DIST_DIR/$APP_NAME"
DMG_NAME="In-Out-macOS.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

cd "$ROOT_DIR"

"$ROOT_DIR/scripts/build_app.sh" release

if [[ ! -d "$APP_PATH" ]]; then
  echo "Release build did not produce app bundle: $APP_PATH"
  exit 1
fi

rm -f "$DMG_PATH"

"$ROOT_DIR/scripts/create_dmg.sh" "$APP_PATH" "$DMG_PATH"

echo "Packaged: $DMG_PATH"
