#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/In-Out.app}"
FFMPEG_PATH="$APP_PATH/Contents/Resources/ffmpeg"

if [[ ! -x "$FFMPEG_PATH" ]]; then
  echo "Smoke test failed: bundled ffmpeg missing or not executable"
  echo "Path: $FFMPEG_PATH"
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bvt-ffmpeg-smoke.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

SOURCE="$TMP_DIR/source.mp4"
STAGE="$TMP_DIR/stage.mp4"
CAPTIONED="$TMP_DIR/captioned.mp4"
SRT="$TMP_DIR/smoke.srt"

cat > "$SRT" <<'SRT'
1
00:00:00,000 --> 00:00:01,200
Smoke test
SRT

escape_subtitles_path() {
  local p="$1"
  p="${p//\\/\\\\}"
  p="${p//:/\\:}"
  p="${p//\'/\\\'}"
  p="${p//,/\\,}"
  echo "$p"
}

echo "Running ffmpeg smoke test..."

"$FFMPEG_PATH" -y -hide_banner -loglevel error \
  -f lavfi -i testsrc2=size=640x360:rate=30 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -t 3.0 \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -c:a aac -b:a 128k \
  "$SOURCE"

"$FFMPEG_PATH" -y -hide_banner -loglevel error \
  -ss 0.500 -i "$SOURCE" -ss 0.250 -t 1.200 \
  -map 0:v:0 -c:v libx264 -preset veryfast -pix_fmt yuv420p -b:v 1200k \
  -map 0:a:0 -c:a aac -b:a 128k \
  -movflags +faststart \
  "$STAGE"

ESCAPED_SRT="$(escape_subtitles_path "$SRT")"
"$FFMPEG_PATH" -y -hide_banner -loglevel error \
  -i "$STAGE" \
  -map 0:v:0 -c:v libx264 -preset veryfast -pix_fmt yuv420p -b:v 1200k \
  -vf "subtitles='$ESCAPED_SRT':force_style='Fontname=Roboto,OutlineColour=&H40000000,BorderStyle=3,MarginV=48,Alignment=2'" \
  -map '0:a:0?' -c:a copy \
  -movflags +faststart \
  "$CAPTIONED"

if [[ ! -s "$CAPTIONED" ]]; then
  echo "Smoke test failed: captioned output missing or empty"
  exit 1
fi

echo "ffmpeg smoke test passed."
