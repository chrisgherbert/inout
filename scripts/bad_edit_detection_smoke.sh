#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/bad-edit-detection-smoke"
CORE_DIR="$OUTPUT_DIR/core"
FFMPEG="${FFMPEG:-$(command -v ffmpeg)}"
mkdir -p "$CORE_DIR"

make_fixture() {
  local output="$1"
  local middle_color="$2"
  local middle_duration="$3"
  "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=white:s=320x180:r=30:d=0.5" \
    -f lavfi -i "color=c=${middle_color}:s=320x180:r=30:d=${middle_duration}" \
    -f lavfi -i "color=c=white:s=320x180:r=30:d=0.5" \
    -filter_complex "[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]" \
    -map "[v]" -c:v libx264 -pix_fmt yuv420p "$output"
}

make_fixture "$OUTPUT_DIR/visual-flash.mp4" red 0.033333
make_fixture "$OUTPUT_DIR/black-flash.mp4" black 0.033333
"$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=white:s=320x180:r=30:d=0.5" \
  -f lavfi -i "color=c=0xFF0000:s=320x180:r=30:d=1.6" \
  -f lavfi -i "color=c=0xF80000:s=320x180:r=30:d=1.6" \
  -f lavfi -i "color=c=white:s=320x180:r=30:d=0.5" \
  -filter_complex "[0:v][1:v][2:v][3:v]concat=n=4:v=1:a=0[v]" \
  -map "[v]" -c:v libx264 -pix_fmt yuv420p "$OUTPUT_DIR/freeze.mp4"
"$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=white:s=320x180:r=30:d=2" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000:d=0.5" \
  -map 0:v -map 1:a -c:v libx264 -pix_fmt yuv420p -c:a aac \
  "$OUTPUT_DIR/stream-mismatch.mp4"
"$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=white:s=320x180:r=30:d=1.4" \
  -f lavfi -i "aevalsrc=if(lt(t\,0.7)\,0.4\,-0.4):s=48000:d=1.4" \
  -map 0:v -map 1:a -c:v libx264 -pix_fmt yuv420p -c:a pcm_s16le \
  "$OUTPUT_DIR/audio-discontinuity.mov"
"$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=white:s=320x180:r=30:d=0.5" \
  -f lavfi -i "color=c=red:s=320x180:r=30:d=0.4" \
  -f lavfi -i "color=c=white:s=320x180:r=30:d=0.5" \
  -f lavfi -i "aevalsrc=if(lt(t\,0.5)\,0.4\,-0.4):s=48000:d=1.4" \
  -filter_complex "[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]" \
  -map "[v]" -map 3:a -c:v libx264 -pix_fmt yuv420p -c:a pcm_s16le \
  "$OUTPUT_DIR/short-shot-clipped-audio.mov"

xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -emit-library \
  -emit-module \
  -module-name InOutCore \
  -emit-module-path "$CORE_DIR/InOutCore.swiftmodule" \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework CoreVideo \
  "$ROOT_DIR"/src-core/*.swift \
  -o "$CORE_DIR/libInOutCore.dylib"

xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -I "$CORE_DIR" \
  -L "$CORE_DIR" \
  -lInOutCore \
  -framework AVFoundation \
  "$ROOT_DIR/scripts/bad_edit_detection_smoke.swift" \
  -o "$OUTPUT_DIR/bad-edit-detection-smoke"

DYLD_LIBRARY_PATH="$CORE_DIR" "$OUTPUT_DIR/bad-edit-detection-smoke" \
  "$OUTPUT_DIR/visual-flash.mp4" \
  "$OUTPUT_DIR/black-flash.mp4" \
  "$OUTPUT_DIR/freeze.mp4" \
  "$OUTPUT_DIR/stream-mismatch.mp4" \
  "$OUTPUT_DIR/audio-discontinuity.mov" \
  "$OUTPUT_DIR/short-shot-clipped-audio.mov"
