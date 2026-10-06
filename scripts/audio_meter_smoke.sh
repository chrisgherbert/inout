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

# A native-rate high-frequency channel catches accidental downsampling before
# level measurement. Both channels have analytically known peak and RMS levels.
"$FFMPEG" \
  -hide_banner \
  -loglevel error \
  -f lavfi \
  -i "aevalsrc=0.5*sin(2*PI*10000*t)|0.25*sin(2*PI*997*t):s=48000:d=8:c=stereo" \
  -c:a pcm_f32le \
  "$TMP_DIR/calibration.wav"

"$FFMPEG" \
  -hide_banner \
  -loglevel error \
  -f lavfi \
  -i "aevalsrc=sin(2*PI*1000*t)|0.5*sin(2*PI*997*t):s=48000:d=2:c=stereo" \
  -c:a pcm_f32le \
  "$TMP_DIR/full-scale.wav"

"$FFMPEG" \
  -hide_banner \
  -loglevel error \
  -f lavfi \
  -i "anullsrc=r=48000:cl=stereo:d=2" \
  -c:a pcm_f32le \
  "$TMP_DIR/silence.wav"

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

PATH="$(dirname "$FFMPEG"):$PATH" "$TMP_DIR/audio-meter-smoke" \
  "$TMP_DIR/stereo.m4a" \
  "$TMP_DIR/calibration.wav" \
  "$TMP_DIR/full-scale.wav" \
  "$TMP_DIR/silence.wav"
