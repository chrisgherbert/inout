#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/In-Out.app}"
PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE="$APP_PATH/Contents/MacOS/BulwarkVideoTools"
FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
EXPECTED_FEED="https://github.com/chrisgherbert/inout/releases/latest/download/appcast.xml"
EXPECTED_KEY="6/pySHU9/kwRnn1qolnPflgpxFo5TWeA66nKjY9I2y0="

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Missing app executable: $EXECUTABLE"
  exit 1
fi
if [[ ! -d "$FRAMEWORK" ]]; then
  echo "Missing Sparkle framework: $FRAMEWORK"
  exit 1
fi

FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST")"
SPARKLE_BUNDLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :SUBundleName' "$PLIST")"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
AUTOMATIC_CHECKS="$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$PLIST")"

[[ "$FEED" == "$EXPECTED_FEED" ]] || { echo "Unexpected Sparkle feed: $FEED"; exit 1; }
[[ "$SPARKLE_BUNDLE_NAME" == "In-Out" ]] || { echo "Unexpected Sparkle bundle name: $SPARKLE_BUNDLE_NAME"; exit 1; }
[[ "$SPARKLE_BUNDLE_NAME" != *'/'* ]] || { echo "Sparkle bundle name cannot contain path separators."; exit 1; }
[[ "$PUBLIC_KEY" == "$EXPECTED_KEY" ]] || { echo "Unexpected Sparkle public key."; exit 1; }
[[ "$AUTOMATIC_CHECKS" == "true" ]] || { echo "Automatic update checks are not enabled."; exit 1; }

if ! otool -L "$EXECUTABLE" | grep -q '@rpath/Sparkle.framework/Versions/B/Sparkle'; then
  echo "App executable is not linked to the bundled Sparkle framework."
  exit 1
fi
if ! otool -l "$EXECUTABLE" | grep -A2 LC_RPATH | grep -q '@executable_path/../Frameworks'; then
  echo "App executable is missing the Sparkle framework runtime search path."
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$FRAMEWORK"
echo "Sparkle smoke test passed: $APP_PATH"
