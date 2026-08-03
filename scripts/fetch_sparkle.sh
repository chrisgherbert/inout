#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_VERSION="2.9.5"
SPARKLE_SHA256="015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc"
SPARKLE_CACHE_DIR="$ROOT_DIR/.build/sparkle"
SPARKLE_ARCHIVE="$SPARKLE_CACHE_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
SPARKLE_DIR="$SPARKLE_CACHE_DIR/$SPARKLE_VERSION"
SPARKLE_FRAMEWORK="$SPARKLE_DIR/Sparkle.framework"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

if [[ -d "$SPARKLE_FRAMEWORK" && -x "$SPARKLE_DIR/bin/generate_appcast" ]]; then
  print -r -- "$SPARKLE_DIR"
  exit 0
fi

mkdir -p "$SPARKLE_CACHE_DIR"
if [[ ! -f "$SPARKLE_ARCHIVE" ]]; then
  echo "Downloading Sparkle $SPARKLE_VERSION..." >&2
  curl -fL --retry 3 "$SPARKLE_URL" -o "$SPARKLE_ARCHIVE"
fi

ACTUAL_SHA256="$(shasum -a 256 "$SPARKLE_ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$SPARKLE_SHA256" ]]; then
  echo "ERROR: Sparkle archive checksum mismatch." >&2
  echo "Expected: $SPARKLE_SHA256" >&2
  echo "Actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

rm -rf "$SPARKLE_DIR"
mkdir -p "$SPARKLE_DIR"
tar -xJf "$SPARKLE_ARCHIVE" -C "$SPARKLE_DIR"

if [[ ! -d "$SPARKLE_FRAMEWORK" || ! -x "$SPARKLE_DIR/bin/generate_appcast" ]]; then
  echo "ERROR: Sparkle distribution is incomplete after extraction." >&2
  exit 1
fi

print -r -- "$SPARKLE_DIR"
