#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/In-Out.app}"
FFMPEG="$APP_PATH/Contents/Resources/ffmpeg"
PARAKEET="$APP_PATH/Contents/Resources/parakeet-transcriber"
MODEL="$APP_PATH/Contents/Resources/parakeet-tdt-0.6b-v2"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/inout-parakeet-caption.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for required in "$FFMPEG" "$PARAKEET"; do
  if [[ ! -x "$required" ]]; then
    echo "Parakeet caption smoke test failed: missing executable $required" >&2
    exit 1
  fi
done
if [[ ! -d "$MODEL" ]]; then
  echo "Parakeet caption smoke test failed: missing model $MODEL" >&2
  exit 1
fi

say -v Samantha "Parakeet captions preserve accurate word timing for exported video." -o "$TMP_DIR/speech.aiff"
"$FFMPEG" -y -hide_banner -loglevel error \
  -i "$TMP_DIR/speech.aiff" -ac 1 -ar 16000 -f wav "$TMP_DIR/speech.wav"

"$PARAKEET" "$TMP_DIR/speech.wav" \
  --model-version v2 \
  --model-dir "$MODEL" \
  --output-json "$TMP_DIR/transcript.json" \
  >"$TMP_DIR/parakeet.stdout"

python3 - "$TMP_DIR/transcript.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    output = json.load(handle)

text = output.get("text", "").strip()
timings = output.get("tokenTimings", [])
if not text:
    raise SystemExit("Parakeet caption smoke test failed: transcript text is empty")
if not timings:
    raise SystemExit("Parakeet caption smoke test failed: token timings are empty")
if not all("startTime" in timing and "endTime" in timing for timing in timings):
    raise SystemExit("Parakeet caption smoke test failed: token timing fields are missing")
if any(timing["endTime"] < timing["startTime"] for timing in timings):
    raise SystemExit("Parakeet caption smoke test failed: token timing range is invalid")

print(f"Parakeet caption integration smoke test passed ({len(timings)} timed tokens).")
PY
