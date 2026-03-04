#!/bin/zsh
set -euo pipefail

FFMPEG_BIN="${1:-}"
if [[ -z "$FFMPEG_BIN" ]]; then
  echo "Usage: $(basename "$0") /path/to/ffmpeg"
  exit 1
fi
if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg binary missing or not executable: $FFMPEG_BIN"
  exit 1
fi

DISALLOWED_PATTERNS=(
  '^/opt/homebrew/'
  '^/usr/local/'
  '^/opt/local/'
  '^/sw/'
)

ALLOWED_PREFIXES=(
  '/System/Library/'
  '/usr/lib/'
  '@rpath/'
  '@loader_path/'
  '@executable_path/'
)

is_allowed() {
  local lib="$1"
  for prefix in "${ALLOWED_PREFIXES[@]}"; do
    if [[ "$lib" == ${prefix}* ]]; then
      return 0
    fi
  done
  return 1
}

offenders=()
while IFS= read -r line; do
  [[ "$line" == *":" ]] && continue
  lib_path="$(echo "$line" | awk '{print $1}')"
  [[ -z "$lib_path" ]] && continue

  for pattern in "${DISALLOWED_PATTERNS[@]}"; do
    if [[ "$lib_path" =~ $pattern ]]; then
      offenders+=("$lib_path")
      continue 2
    fi
  done

  if [[ "$lib_path" == /* ]]; then
    if ! is_allowed "$lib_path"; then
      offenders+=("$lib_path")
    fi
  fi
done < <(otool -L "$FFMPEG_BIN")

if [[ ${#offenders[@]} -gt 0 ]]; then
  echo "ERROR: ffmpeg has non-portable dynamic library dependencies:"
  printf '  %s\n' "${offenders[@]}" | sort -u
  echo ""
  echo "Use a self-contained/static ffmpeg build, or relink dependencies to @rpath and bundle/sign all dylibs."
  exit 1
fi

echo "ffmpeg dependency audit passed: no non-portable dylib links detected."
