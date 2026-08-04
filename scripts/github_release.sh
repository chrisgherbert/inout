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
RELEASE_NOTES_DIR="$ROOT_DIR/release-notes"
APPCAST_PATH="$DIST_DIR/appcast.xml"
SPARKLE_KEY_ACCOUNT="com.bulwark.BulwarkVideoTools"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--version X.Y.Z] [--build-number N] [--notes-file PATH] [--skip-notarize]

Creates/updates a GitHub release and uploads notarized macOS artifacts.

Examples:
  $(basename "$0")
  $(basename "$0") --version 1.3.0
  $(basename "$0") --version 1.3.0 --notes-file release-notes/v1.3.0.md
  $(basename "$0") --version 1.3.1 --build-number 202603041030
USAGE
}

VERSION=""
BUILD_NUMBER=""
RELEASE_NOTES_SOURCE=""
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
    --notes-file)
      RELEASE_NOTES_SOURCE="${2:-}"
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

CURRENT_BRANCH="$(git branch --show-current)"
if [[ -z "$CURRENT_BRANCH" ]]; then
  echo "Release must be created from a named Git branch."
  exit 1
fi
git fetch origin "$CURRENT_BRANCH" --quiet
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$CURRENT_BRANCH")" ]]; then
  echo "Local $CURRENT_BRANCH does not match origin/$CURRENT_BRANCH."
  echo "Push the tested release commit before creating the GitHub release."
  exit 1
fi

TAG="v$VERSION"
if [[ -z "$RELEASE_NOTES_SOURCE" ]]; then
  RELEASE_NOTES_SOURCE="$RELEASE_NOTES_DIR/$TAG.md"
elif [[ "$RELEASE_NOTES_SOURCE" != /* ]]; then
  RELEASE_NOTES_SOURCE="$ROOT_DIR/$RELEASE_NOTES_SOURCE"
fi

if ! "$ROOT_DIR/scripts/release_notes_smoke.sh" "$RELEASE_NOTES_SOURCE"; then
  echo "Create $RELEASE_NOTES_DIR/$TAG.md or pass --notes-file PATH."
  exit 1
fi

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

cp "$RELEASE_NOTES_SOURCE" "$NOTES_PATH"

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

verify_release_asset() {
  local asset_path="$1"
  local asset_name="$(basename "$asset_path")"
  local local_size="$(stat -f '%z' "$asset_path")"
  local remote_size
  remote_size="$(gh release view "$TAG" --json assets | python3 -c '
import json
import sys

asset_name = sys.argv[1]
assets = json.load(sys.stdin).get("assets", [])
for asset in assets:
    if asset.get("name") == asset_name:
        print(asset.get("size", ""))
        break
' "$asset_name")"

  if [[ -z "$remote_size" || "$remote_size" != "$local_size" ]]; then
    echo "Release asset verification failed: $asset_name (local $local_size, remote ${remote_size:-missing})"
    return 1
  fi
  echo "Verified release asset: $asset_name ($local_size bytes)"
}

upload_release_payload() {
  gh release upload \
    "$TAG" \
    "$VERSIONED_DMG" \
    "$SHA_PATH" \
    "$RUNTIME_ARCHIVE" \
    "$RUNTIME_SHA_PATH" \
    --clobber

  verify_release_asset "$VERSIONED_DMG"
  verify_release_asset "$SHA_PATH"
  verify_release_asset "$RUNTIME_ARCHIVE"
  verify_release_asset "$RUNTIME_SHA_PATH"
}

upload_and_verify_appcast() {
  gh release upload "$TAG" "$APPCAST_PATH" --clobber
  verify_release_asset "$APPCAST_PATH"
}

return_release_to_draft() {
  echo "Returning $TAG to draft because its public update assets are not ready."
  gh release edit "$TAG" --draft=true || true
}

publish_staged_release() {
  upload_release_payload

  echo "Publishing release after payload verification..."
  gh release edit "$TAG" --draft=false

  PUBLIC_DMG_URL="https://github.com/chrisgherbert/inout/releases/download/$TAG/$(basename "$VERSIONED_DMG")"
  echo "Waiting for the public DMG download to become available..."
  if ! curl \
      --fail \
      --location \
      --head \
      --retry 8 \
      --retry-all-errors \
      --retry-delay 2 \
      --silent \
      --show-error \
      "$PUBLIC_DMG_URL" >/dev/null; then
    return_release_to_draft
    return 1
  fi

  # Upload the feed last so installed apps cannot discover a release whose
  # large DMG is still uploading or propagating through GitHub's CDN.
  if ! upload_and_verify_appcast; then
    return_release_to_draft
    return 1
  fi
}

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release edit "$TAG" --notes-file "$NOTES_PATH"
  IS_DRAFT="$(gh release view "$TAG" --json isDraft --jq '.isDraft')"
  if [[ "$IS_DRAFT" == "true" ]]; then
    echo "Resuming staged draft release $TAG..."
    publish_staged_release
  else
    echo "Release $TAG already exists; uploading updated assets..."
    upload_release_payload
    upload_and_verify_appcast
  fi
else
  CREATE_ARGS=(
    "$TAG"
    --title "In/Out $TAG"
    --notes-file "$NOTES_PATH"
    --draft
  )
  if [[ "$VERSION" == *"-"* ]]; then
    CREATE_ARGS+=(--prerelease)
  fi
  gh release create "${CREATE_ARGS[@]}"
  publish_staged_release
fi

echo "Done"
echo "GitHub release: $TAG"
echo "Uploaded asset: $VERSIONED_DMG"
echo "Checksum file:  $SHA_PATH"
echo "Runtime asset:  $RUNTIME_ARCHIVE"
echo "Runtime sha:    $RUNTIME_SHA_PATH"
echo "Sparkle feed:   $APPCAST_PATH"
