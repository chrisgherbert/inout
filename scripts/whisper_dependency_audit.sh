#!/bin/zsh
set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" ]]; then
  echo "Usage: $(basename "$0") /path/to/In-Out.app"
  exit 1
fi

RES_DIR="$APP_PATH/Contents/Resources"
WHISPER_BIN="$RES_DIR/whisper-cli"

if [[ ! -x "$WHISPER_BIN" ]]; then
  echo "whisper-cli missing or not executable: $WHISPER_BIN"
  exit 1
fi

allowed_absolute_prefixes=(
  "/System/Library/"
  "/usr/lib/"
)

is_allowed_absolute() {
  local p="$1"
  local prefix
  for prefix in "${allowed_absolute_prefixes[@]}"; do
    if [[ "$p" == ${prefix}* ]]; then
      return 0
    fi
  done
  return 1
}

errors=()

deps="$(otool -L "$WHISPER_BIN" | awk 'NR>1{print $1}')"
while IFS= read -r dep; do
  [[ -z "$dep" ]] && continue
  if [[ "$dep" == @rpath/* ]]; then
    base="${dep#@rpath/}"
    if [[ ! -e "$RES_DIR/$base" ]]; then
      errors+=("Missing bundled whisper dependency: $base")
    fi
  elif [[ "$dep" == /* ]]; then
    if ! is_allowed_absolute "$dep"; then
      errors+=("Non-portable absolute dependency in whisper-cli: $dep")
    fi
  fi
done <<< "$deps"

for lib in "$RES_DIR"/libwhisper*.dylib "$RES_DIR"/libggml*.dylib; do
  [[ -e "$lib" ]] || continue
  lib_deps="$(otool -L "$lib" | awk 'NR>1{print $1}')"
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    if [[ "$dep" == @rpath/* ]]; then
      base="${dep#@rpath/}"
      if [[ ! -e "$RES_DIR/$base" ]]; then
        errors+=("Missing transitive whisper dependency: $base (required by $(basename "$lib"))")
      fi
    elif [[ "$dep" == /* ]]; then
      if ! is_allowed_absolute "$dep"; then
        errors+=("Non-portable absolute dependency in $(basename "$lib"): $dep")
      fi
    fi
  done <<< "$lib_deps"
done

if [[ ${#errors[@]} -gt 0 ]]; then
  echo "ERROR: whisper dependency audit failed:"
  printf '  %s\n' "${errors[@]}"
  exit 1
fi

echo "whisper dependency audit passed."
