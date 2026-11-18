#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/In-Out.app}"
SIGNING_IDENTITY="${INOUT_CODE_SIGN_IDENTITY:-}"

# Match release signing so local and distributed builds have the same identity.
# Read the existing configuration in a subshell to keep release settings isolated.
if [[ -z "$SIGNING_IDENTITY" && -f "$ROOT_DIR/scripts/release.env" ]]; then
  SIGNING_IDENTITY="$(
    source "$ROOT_DIR/scripts/release.env"
    print -r -- "${DEV_ID_APP:-}"
  )"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "Local certificate signing skipped: set INOUT_CODE_SIGN_IDENTITY or DEV_ID_APP in scripts/release.env."
  echo "Without certificate signing, rebuilt apps may prompt again for Keychain access."
  exit 0
fi
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Local signing requires a certificate; ad hoc signing cannot preserve Keychain trust across builds." >&2
  exit 1
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

# Preserve vendor signatures on bundled tools/frameworks. Local builds don't need
# hardened runtime, a timestamp service, or a notarization submission.
/usr/bin/codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_PATH"
/usr/bin/codesign --verify --strict "$APP_PATH"
echo "Locally signed: $SIGNING_IDENTITY"
