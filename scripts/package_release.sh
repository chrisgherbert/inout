#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Bulwark Video Tools.app"
APP_PATH="$DIST_DIR/$APP_NAME"
ZIP_NAME="Bulwark-Video-Tools-macOS.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

cd "$ROOT_DIR"

"$ROOT_DIR/scripts/build_app.sh" release

if [[ ! -d "$APP_PATH" ]]; then
  echo "Release build did not produce app bundle: $APP_PATH"
  exit 1
fi

rm -f "$ZIP_PATH"

ditto -c -k --sequesterRsrc --keepParent \
  "$APP_PATH" \
  "$ZIP_PATH"

echo "Packaged: $ZIP_PATH"
