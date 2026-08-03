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
NOTARIZED_DMG="$DIST_DIR/In-Out-macOS.dmg"
NOTES_PATH="$DIST_DIR/release-notes.md"
APPCAST_PATH="$DIST_DIR/appcast.xml"
SPARKLE_KEY_ACCOUNT="com.bulwark.BulwarkVideoTools"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--version X.Y.Z] [--build-number N] [--skip-notarize]

Creates/updates a GitHub release and uploads notarized macOS artifacts.

Examples:
  $(basename "$0")
  $(basename "$0") --version 1.3.0
  $(basename "$0") --version 1.3.1 --build-number 202603041030
USAGE
}

VERSION=""
BUILD_NUMBER=""
SKIP_NOTARIZE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --skip-notarize)
      SKIP_NOTARIZE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

cd "$ROOT_DIR"

if [[ -z "$VERSION" ]]; then
  print -n "Version (semver, e.g. 1.4.0): "
  read -r VERSION
fi

# Semver: MAJOR.MINOR.PATCH with optional prerelease/build metadata suffixes.
if ! python3 - "$VERSION" <<'PY'
import re
import sys
v = sys.argv[1]
pattern = r'^[0-9]+\.[0-9]+\.[0-9]+([\-+][0-9A-Za-z\.-]+)?$'
sys.exit(0 if re.match(pattern, v) else 1)
PY
then
  echo "Invalid version: $VERSION"
  echo "Expected semantic version like 1.4.0 or 1.5.0-beta.1"
  exit 1
fi

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(date +%Y%m%d%H%M)"
fi

if [[ ! "$BUILD_NUMBER" =~ '^[0-9]+$' ]]; then
  echo "Invalid build number: $BUILD_NUMBER"
  echo "Build number must be numeric."
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required. Install it and run 'gh auth login'."
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run: gh auth login"
  exit 1
fi

TAG="v$VERSION"
VERSIONED_DMG="$DIST_DIR/In-Out-macOS-$TAG.dmg"
SHA_PATH="$VERSIONED_DMG.sha256"
RUNTIME_ARCHIVE="$DIST_DIR/In-Out-python-runtime.tar.gz"
RUNTIME_SHA_PATH="$DIST_DIR/In-Out-python-runtime.tar.gz.sha256"

echo "Release version: $VERSION"
echo "Build number:    $BUILD_NUMBER"
echo "Tag:             $TAG"

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  APP_VERSION="$VERSION" APP_BUILD_NUMBER="$BUILD_NUMBER" "$ROOT_DIR/scripts/notarize_release.sh"
else
  echo "Skipping notarization step (--skip-notarize)."
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH"
  exit 1
fi
if [[ ! -f "$NOTARIZED_DMG" ]]; then
  echo "Notarized DMG not found: $NOTARIZED_DMG"
  exit 1
fi
if [[ ! -f "$RUNTIME_ARCHIVE" ]]; then
  echo "Managed Python runtime archive not found: $RUNTIME_ARCHIVE"
  exit 1
fi
if [[ ! -f "$RUNTIME_SHA_PATH" ]]; then
  echo "Managed Python runtime checksum not found: $RUNTIME_SHA_PATH"
  exit 1
fi

cp "$NOTARIZED_DMG" "$VERSIONED_DMG"
shasum -a 256 "$VERSIONED_DMG" > "$SHA_PATH"

cat > "$NOTES_PATH" <<EOF
In/Out $TAG

Artifacts:
- $(basename "$VERSIONED_DMG")
- $(basename "$SHA_PATH")
- $(basename "$RUNTIME_ARCHIVE")
- $(basename "$RUNTIME_SHA_PATH")

Build metadata:
- CFBundleShortVersionString: $VERSION
- CFBundleVersion: $BUILD_NUMBER
EOF

SPARKLE_DIR="$($ROOT_DIR/scripts/fetch_sparkle.sh)"
APPCAST_INPUT_DIR="$DIST_DIR/sparkle-appcast-input"
rm -rf "$APPCAST_INPUT_DIR"
mkdir -p "$APPCAST_INPUT_DIR"
cp "$VERSIONED_DMG" "$APPCAST_INPUT_DIR/"
cp "$NOTES_PATH" "$APPCAST_INPUT_DIR/$(basename "${VERSIONED_DMG%.dmg}").md"

echo "Generating signed Sparkle appcast..."
"$SPARKLE_DIR/bin/generate_appcast" \
  --account "$SPARKLE_KEY_ACCOUNT" \
  --download-url-prefix "https://github.com/chrisgherbert/inout/releases/download/$TAG/" \
  --link "https://chrisgherbert.github.io/inout/" \
  --maximum-deltas 0 \
  --embed-release-notes \
  -o "$APPCAST_PATH" \
  "$APPCAST_INPUT_DIR"

xmllint --noout "$APPCAST_PATH"
if ! grep -q 'sparkle:edSignature=' "$APPCAST_PATH"; then
  echo "Generated appcast does not contain a Sparkle EdDSA signature."
  exit 1
fi
if ! grep -Fq "releases/download/$TAG/$(basename "$VERSIONED_DMG")" "$APPCAST_PATH"; then
  echo "Generated appcast does not reference the expected release DMG."
  exit 1
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists; uploading updated assets..."
  gh release upload \
    "$TAG" \
    "$VERSIONED_DMG" \
    "$SHA_PATH" \
    "$RUNTIME_ARCHIVE" \
    "$RUNTIME_SHA_PATH" \
    "$APPCAST_PATH" \
    --clobber
else
  CREATE_ARGS=(
    "$TAG"
    "$VERSIONED_DMG"
    "$SHA_PATH"
    "$RUNTIME_ARCHIVE"
    "$RUNTIME_SHA_PATH"
    "$APPCAST_PATH"
    --title "In/Out $TAG"
    --notes-file "$NOTES_PATH"
  )
  if [[ "$VERSION" == *"-"* ]]; then
    CREATE_ARGS+=(--prerelease)
  fi
  gh release create "${CREATE_ARGS[@]}"
fi

echo "Done"
echo "GitHub release: $TAG"
echo "Uploaded asset: $VERSIONED_DMG"
echo "Checksum file:  $SHA_PATH"
echo "Runtime asset:  $RUNTIME_ARCHIVE"
echo "Runtime sha:    $RUNTIME_SHA_PATH"
echo "Sparkle feed:   $APPCAST_PATH"
