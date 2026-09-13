#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/inout-audio-meter-smoke.XXXXXX")"
trap 'find "$TMP_DIR" -depth -delete' EXIT

FFMPEG="${FFMPEG_BIN:-$ROOT_DIR/vendor/ffmpeg/macos-arm64/ffmpeg}"
if [[ ! -x "$FFMPEG" ]]; then
  echo "ERROR: ffmpeg is required for the audio meter smoke test" >&2
  exit 1
fi

"$FFMPEG" \
  -hide_banner \
  -loglevel error \
  -f lavfi -i "sine=frequency=440:duration=40" \
  -f lavfi -i "sine=frequency=880:duration=40" \
  -filter_complex "[0:a]tremolo=f=7:d=0.8,volume=0.25[left];[1:a]tremolo=f=7:d=0.8,volume=0.5[right];[left][right]amerge=inputs=2[audio]" \
  -map "[audio]" \
  -c:a aac \
  -b:a 192k \
  "$TMP_DIR/stereo.m4a"

xcrun swiftc \
  -parse-as-library \
  -emit-module \
  -emit-module-path "$TMP_DIR/InOutCore.swiftmodule" \
  -emit-object \
  -module-name InOutCore \
  "$ROOT_DIR/src-core/ToolDiscoveryUtilities.swift" \
  -o "$TMP_DIR/InOutCore.o"

xcrun swiftc \
  -parse-as-library \
  "$ROOT_DIR/src/AudioMetering.swift" \
  "$ROOT_DIR/scripts/audio_meter_smoke.swift" \
  "$TMP_DIR/InOutCore.o" \
  -I "$TMP_DIR" \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework Foundation \
  -o "$TMP_DIR/audio-meter-smoke"

PATH="$(dirname "$FFMPEG"):$PATH" "$TMP_DIR/audio-meter-smoke" "$TMP_DIR/stereo.m4a"
