#!/bin/zsh
set -euo pipefail

LAST_CMD=""
CURRENT_CMD=""
trap 'LAST_CMD=$CURRENT_CMD; CURRENT_CMD=${ZSH_DEBUG_CMD:-}' DEBUG
trap 'ec=$?; echo ""; echo "ERROR: command failed (exit $ec) at line $LINENO"; if [[ -n "${LAST_CMD:-}" ]]; then echo "FAILED COMMAND: $LAST_CMD"; fi; exit $ec' ERR

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="In-Out.app"
APP_PATH="$DIST_DIR/$APP_NAME"
DMG_NAME="In-Out-macOS.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
RELEASE_ENV="$ROOT_DIR/scripts/release.env"
YTDLP_ENTITLEMENTS="$ROOT_DIR/scripts/yt-dlp.entitlements"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--skip-build] [--skip-staple] [--skip-smoke]

Required config: scripts/release.env
  export DEV_ID_APP="Developer ID Application: Your Name (TEAMID)"
  export AC_PROFILE="notarytool-keychain-profile"

This script will:
  1) Build release app (unless --skip-build)
  2) Sign nested executables with runtime+timestamp
  3) Sign app bundle with runtime+timestamp
  4) Verify signature
  5) Build installer DMG
  6) Submit and wait for notarization
  7) Staple ticket(s) (unless --skip-staple)
  8) Run Gatekeeper assessment
USAGE
}

SKIP_BUILD=0
SKIP_STAPLE=0
SKIP_SMOKE=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --skip-staple) SKIP_STAPLE=1 ;;
    --skip-smoke) SKIP_SMOKE=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $arg"
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "$RELEASE_ENV" ]]; then
  echo "Missing config: $RELEASE_ENV"
  echo "Copy scripts/release.env.example -> scripts/release.env and fill values."
  exit 1
fi

# shellcheck disable=SC1090
source "$RELEASE_ENV"

if [[ -z "${DEV_ID_APP:-}" ]]; then
  echo "DEV_ID_APP is required in $RELEASE_ENV"
  exit 1
fi
if [[ -z "${AC_PROFILE:-}" ]]; then
  echo "AC_PROFILE is required in $RELEASE_ENV"
  exit 1
fi
if [[ "${DEV_ID_APP}" == *"COMPANY NAME"* || "${DEV_ID_APP}" == *"YOUR_TEAM_ID"* ]]; then
  echo "DEV_ID_APP in $RELEASE_ENV is still using placeholder text:"
  echo "  $DEV_ID_APP"
  echo "Set it to the exact certificate common name from keychain, e.g.:"
  echo "  Developer ID Application: Chris Herbert (Z9V2EC7ASL)"
  exit 1
fi
if [[ "${AC_PROFILE}" == "notarytool-profile-name" || "${AC_PROFILE}" == *"YOUR_"* ]]; then
  echo "AC_PROFILE in $RELEASE_ENV is still using placeholder text:"
  echo "  $AC_PROFILE"
  echo "Set it to your real notarytool keychain profile name."
  exit 1
fi

cd "$ROOT_DIR"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  "$ROOT_DIR/scripts/build_app.sh" release
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH"
  exit 1
fi

if [[ "$SKIP_SMOKE" -eq 0 ]]; then
  "$ROOT_DIR/scripts/ffmpeg_dependency_audit.sh" "$APP_PATH/Contents/Resources/ffmpeg"
  "$ROOT_DIR/scripts/ffmpeg_dependency_audit.sh" "$APP_PATH/Contents/Resources/ffprobe"
  "$ROOT_DIR/scripts/ytdlp_portability_audit.sh" "$APP_PATH/Contents/Resources/yt-dlp"
  "$ROOT_DIR/scripts/whisper_dependency_audit.sh" "$APP_PATH"
  if [[ ! -x "$APP_PATH/Contents/Resources/yt-dlp" ]]; then
    echo "Missing bundled yt-dlp: $APP_PATH/Contents/Resources/yt-dlp"
    exit 1
  fi
  echo "Running bundled yt-dlp smoke test..."
  "$APP_PATH/Contents/Resources/yt-dlp" --version >/dev/null
  echo "Running bundled ffmpeg smoke tests..."
  "$ROOT_DIR/scripts/ffmpeg_release_smoke.sh" "$APP_PATH"
fi

echo "Checking signing identity availability..."
if ! security find-identity -v -p codesigning | grep -F "$DEV_ID_APP" >/dev/null; then
  echo "Signing identity not found in keychain:"
  echo "  $DEV_ID_APP"
  echo ""
  echo "Available code-signing identities:"
  security find-identity -v -p codesigning || true
  exit 1
fi

echo "Signing nested binaries..."
for binary in "$APP_PATH/Contents/Resources/ffmpeg" "$APP_PATH/Contents/Resources/ffprobe" "$APP_PATH/Contents/Resources/whisper-cli" "$APP_PATH"/Contents/Resources/libwhisper*.dylib "$APP_PATH"/Contents/Resources/libggml*.dylib; do
  if [[ -f "$binary" ]]; then
    codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$binary"
  else
    echo "Warning: nested binary not found, skipping: $binary"
  fi
done

if [[ -f "$APP_PATH/Contents/Resources/yt-dlp" ]]; then
  if [[ ! -f "$YTDLP_ENTITLEMENTS" ]]; then
    echo "Missing yt-dlp entitlements file: $YTDLP_ENTITLEMENTS"
    exit 1
  fi
  if file "$APP_PATH/Contents/Resources/yt-dlp" | grep -q "Mach-O"; then
    codesign --force --options runtime --timestamp --entitlements "$YTDLP_ENTITLEMENTS" --sign "$DEV_ID_APP" "$APP_PATH/Contents/Resources/yt-dlp"
  else
    # Script-style yt-dlp (recommended) should not be signed as a nested runtime binary.
    # It is sealed by the parent app signature.
    echo "yt-dlp is script-style; skipping nested runtime codesign."
  fi
else
  echo "Warning: nested binary not found, skipping: $APP_PATH/Contents/Resources/yt-dlp"
fi

echo "Signing app bundle..."
# Important: do NOT use --deep here.
# We sign nested binaries explicitly above (including yt-dlp with custom entitlements).
# A deep re-sign can replace nested signatures/entitlements and break runtime behavior.
codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$APP_PATH"

echo "Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

rm -f "$DMG_PATH"
echo "Creating installer DMG: $DMG_PATH"
"$ROOT_DIR/scripts/create_dmg.sh" "$APP_PATH" "$DMG_PATH"

echo "Submitting for notarization..."
if ! SUBMISSION_JSON="$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$AC_PROFILE" --output-format json 2>&1)"; then
  echo "Notary submit failed."
  echo "Output:"
  echo "$SUBMISSION_JSON"
  exit 1
fi

if ! SUBMISSION_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<< "$SUBMISSION_JSON" 2>/dev/null)"; then
  echo "Could not parse submission id from notarytool output:"
  echo "$SUBMISSION_JSON"
  exit 1
fi

echo "Waiting for notarization: $SUBMISSION_ID"
if ! WAIT_JSON="$(xcrun notarytool wait "$SUBMISSION_ID" --keychain-profile "$AC_PROFILE" --output-format json 2>&1)"; then
  echo "Notary wait failed for submission: $SUBMISSION_ID"
  echo "Output:"
  echo "$WAIT_JSON"
  LOG_PATH="$DIST_DIR/notary-log-$SUBMISSION_ID.json"
  if xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$AC_PROFILE" "$LOG_PATH" >/dev/null 2>&1; then
    echo "Fetched notary log: $LOG_PATH"
  fi
  exit 1
fi

if ! STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<< "$WAIT_JSON" 2>/dev/null)"; then
  echo "Could not parse notarization wait output:"
  echo "$WAIT_JSON"
  exit 1
fi

echo "Notarization status: $STATUS"
if [[ "$STATUS" != "Accepted" ]]; then
  LOG_PATH="$DIST_DIR/notary-log-$SUBMISSION_ID.json"
  if ! xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$AC_PROFILE" "$LOG_PATH"; then
    echo "Failed to fetch notarization log for: $SUBMISSION_ID"
    echo "wait output:"
    echo "$WAIT_JSON"
    exit 1
  fi
  echo "Notarization failed. Log written to: $LOG_PATH"
  echo "Open it with:"
  echo "  cat \"$LOG_PATH\""
  exit 1
fi

if [[ "$SKIP_STAPLE" -eq 0 ]]; then
  echo "Stapling ticket..."
  xcrun stapler staple "$APP_PATH"
  xcrun stapler staple "$DMG_PATH"
fi

echo "Running Gatekeeper assessment..."
spctl --assess --type execute --verbose=4 "$APP_PATH"
xcrun stapler validate "$DMG_PATH"

echo "Done"
echo "App: $APP_PATH"
echo "DMG: $DMG_PATH"
