#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_DIR="${TRANSCRIPTION_FIXTURE_DIR:-$ROOT_DIR/fixtures/transcription}"
ARTIFACT_ROOT="${TRANSCRIPTION_BENCHMARK_ARTIFACTS:-$ROOT_DIR/.build/transcription-benchmark}"
FLUID_AUDIO_DIR="${FLUID_AUDIO_DIR:-$ROOT_DIR/.build/FluidAudio}"
FLUID_AUDIO_REF="${FLUID_AUDIO_REF:-v0.15.3}"
PARAKEET_HELPER_PACKAGE="${PARAKEET_HELPER_PACKAGE:-$ROOT_DIR/tools/parakeet-transcriber}"
PARAKEET_RUNNER_DIR="${PARAKEET_RUNNER_DIR:-$ROOT_DIR/.build/parakeet-transcriber}"
PARAKEET_HELPER_BIN="$PARAKEET_RUNNER_DIR/release/ParakeetTranscriber"
RUN_WHISPER=1
RUN_PARAKEET=1
UPDATE_FLUID_AUDIO=1

usage() {
  cat <<'EOF'
Usage: scripts/transcription_benchmark.sh [options]

Benchmarks local transcription fixtures against the current bundled Whisper path
and/or the app's Parakeet Core ML helper.

Options:
  --fixtures PATH      Fixture directory. Defaults to fixtures/transcription.
  --artifacts PATH     Output directory. Defaults to .build/transcription-benchmark.
  --whisper-only       Run only the current Whisper backend.
  --parakeet-only      Run only the Parakeet backend.
  --skip-whisper       Do not run Whisper.
  --skip-parakeet      Do not run Parakeet.
  --no-update          Do not update an existing FluidAudio checkout.
  --help               Show this help.

Environment:
  WHISPER_CLI          Override whisper-cli path.
  WHISPER_MODEL        Override ggml Whisper model path.
  FFMPEG               Override ffmpeg path.
  FFPROBE              Override ffprobe path.
  PARAKEET_MODEL_DIR   Override Parakeet v2 Core ML model directory.
  FLUID_AUDIO_DIR      Override FluidAudio checkout path.
  FLUID_AUDIO_REF      Git ref to checkout for FluidAudio. Defaults to v0.15.3.
  PARAKEET_HELPER_PACKAGE  Override Parakeet helper package path.
  PARAKEET_RUNNER_DIR      Override Parakeet helper build directory.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixtures)
      FIXTURE_DIR="$2"
      shift 2
      ;;
    --artifacts)
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
    --whisper-only)
      RUN_WHISPER=1
      RUN_PARAKEET=0
      shift
      ;;
    --parakeet-only)
      RUN_WHISPER=0
      RUN_PARAKEET=1
      shift
      ;;
    --skip-whisper)
      RUN_WHISPER=0
      shift
      ;;
    --skip-parakeet)
      RUN_PARAKEET=0
      shift
      ;;
    --no-update)
      UPDATE_FLUID_AUDIO=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

now_seconds() {
  zmodload zsh/datetime 2>/dev/null || true
  printf "%.6f" "$EPOCHREALTIME"
}

elapsed_seconds() {
  local start="$1"
  local end="$2"
  awk -v start="$start" -v end="$end" 'BEGIN { printf "%.3f", end - start }'
}

find_executable() {
  local override="$1"
  shift

  if [[ -n "$override" && -x "$override" ]]; then
    echo "$override"
    return 0
  fi

  local candidate
  for candidate in "$@"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

find_file() {
  local override="$1"
  shift

  if [[ -n "$override" && -f "$override" ]]; then
    echo "$override"
    return 0
  fi

  local candidate
  for candidate in "$@"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

safe_stem() {
  local file="$1"
  basename "$file" | sed 's/\.[^.]*$//' | tr -cs 'A-Za-z0-9._-' '-' | sed 's/-$//'
}

duration_seconds() {
  local file="$1"
  if [[ -n "$FFPROBE_BIN" ]]; then
    "$FFPROBE_BIN" -v error -show_entries format=duration -of default=nw=1:nk=1 "$file" 2>/dev/null | awk '{ printf "%.3f", $1 }'
  else
    printf "0.000"
  fi
}

realtime_factor() {
  local duration="$1"
  local elapsed="$2"
  awk -v duration="$duration" -v elapsed="$elapsed" 'BEGIN {
    if (elapsed <= 0 || duration <= 0) { printf "n/a" } else { printf "%.2fx", duration / elapsed }
  }'
}

line_count() {
  local file="$1"
  if [[ -f "$file" ]]; then
    wc -l < "$file" | tr -d ' '
  else
    printf "0"
  fi
}

json_segment_count() {
  local file="$1"
  if [[ -f "$file" ]]; then
    /usr/bin/python3 - "$file" <<'PY' 2>/dev/null || printf "n/a"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

if isinstance(data, dict):
    if isinstance(data.get("transcription"), list):
        print(len(data["transcription"]))
    elif isinstance(data.get("segments"), list):
        print(len(data["segments"]))
    elif isinstance(data.get("wordTimings"), list):
        print(len(data["wordTimings"]))
    elif isinstance(data.get("tokenTimings"), list):
        print(len(data["tokenTimings"]))
    else:
        print("n/a")
elif isinstance(data, list):
    print(len(data))
else:
    print("n/a")
PY
  else
    printf "n/a"
  fi
}

ensure_fluid_audio() {
  if [[ -d "$FLUID_AUDIO_DIR/.git" ]]; then
    if [[ "$UPDATE_FLUID_AUDIO" -eq 1 ]]; then
      git -C "$FLUID_AUDIO_DIR" fetch --depth 1 origin "$FLUID_AUDIO_REF"
      git -C "$FLUID_AUDIO_DIR" checkout FETCH_HEAD
    fi
    return 0
  fi

  mkdir -p "$(dirname "$FLUID_AUDIO_DIR")"
  git clone --depth 1 --branch "$FLUID_AUDIO_REF" https://github.com/FluidInference/FluidAudio.git "$FLUID_AUDIO_DIR"
}

ensure_parakeet_runner() {
  swift build \
    --package-path "$PARAKEET_HELPER_PACKAGE" \
    --build-path "$PARAKEET_RUNNER_DIR" \
    -c release
}

run_logged() {
  local log_file="$1"
  shift
  "$@" >"$log_file" 2>&1
}

mkdir -p "$ARTIFACT_ROOT/audio" "$ARTIFACT_ROOT/whisper" "$ARTIFACT_ROOT/parakeet"

FFMPEG_BIN="$(find_executable "${FFMPEG:-}" \
  "$ROOT_DIR/vendor/ffmpeg/macos-arm64/ffmpeg" \
  "$(command -v ffmpeg 2>/dev/null || true)" || true)"
FFPROBE_BIN="$(find_executable "${FFPROBE:-}" \
  "$ROOT_DIR/vendor/ffmpeg/macos-arm64/ffprobe" \
  "$(command -v ffprobe 2>/dev/null || true)" || true)"
WHISPER_CLI_BIN="$(find_executable "${WHISPER_CLI:-}" \
  "$ROOT_DIR/dist/In-Out.app/Contents/Resources/whisper-cli" \
  "$ROOT_DIR/.build/whisper.cpp/build-no-coreml/bin/whisper-cli" \
  "$ROOT_DIR/.build/whisper.cpp/build/bin/whisper-cli" || true)"
WHISPER_MODEL_BIN="$(find_file "${WHISPER_MODEL:-}" \
  "$ROOT_DIR/dist/In-Out.app/Contents/Resources/profanity-model.bin" \
  "$ROOT_DIR/vendor/models/ggml-tiny.en.bin" || true)"
PARAKEET_MODEL_DIR="${PARAKEET_MODEL_DIR:-}"
if [[ -z "$PARAKEET_MODEL_DIR" && -d "$ROOT_DIR/dist/In-Out.app/Contents/Resources/parakeet-tdt-0.6b-v2" ]]; then
  PARAKEET_MODEL_DIR="$ROOT_DIR/dist/In-Out.app/Contents/Resources/parakeet-tdt-0.6b-v2"
elif [[ -z "$PARAKEET_MODEL_DIR" && -d "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2" ]]; then
  PARAKEET_MODEL_DIR="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2"
fi

if [[ -z "$FFMPEG_BIN" ]]; then
  echo "ffmpeg not found. Set FFMPEG=/path/to/ffmpeg or run scripts/pin_ffmpeg.sh." >&2
  exit 1
fi

if [[ "$RUN_WHISPER" -eq 1 && ( -z "$WHISPER_CLI_BIN" || -z "$WHISPER_MODEL_BIN" ) ]]; then
  echo "Whisper resources not found. Build the app first or set WHISPER_CLI and WHISPER_MODEL." >&2
  exit 1
fi

typeset -a fixtures
fixtures=()
local_fixture=""
for local_fixture in "$FIXTURE_DIR"/*(.N); do
  case "${local_fixture:l}" in
    *.mp3|*.wav|*.m4a|*.aac|*.mov|*.mp4|*.mkv)
      fixtures+=("$local_fixture")
      ;;
  esac
done

if [[ ${#fixtures[@]} -eq 0 ]]; then
  echo "No media fixtures found in $FIXTURE_DIR" >&2
  exit 1
fi

if [[ "$RUN_PARAKEET" -eq 1 ]]; then
  if [[ -z "$PARAKEET_MODEL_DIR" || ! -d "$PARAKEET_MODEL_DIR" ]]; then
    echo "Parakeet model not found. Run a Parakeet benchmark once on a networked machine or set PARAKEET_MODEL_DIR." >&2
    exit 1
  fi
  ensure_parakeet_runner
fi

REPORT="$ARTIFACT_ROOT/report.md"
SUMMARY="$ARTIFACT_ROOT/summary.tsv"

cat >"$REPORT" <<EOF
# Transcription Benchmark

- Fixture directory: \`$FIXTURE_DIR\`
- Artifacts: \`$ARTIFACT_ROOT\`
- ffmpeg: \`$FFMPEG_BIN\`
- Whisper CLI: \`${WHISPER_CLI_BIN:-not run}\`
- Whisper model: \`${WHISPER_MODEL_BIN:-not run}\`
- FluidAudio: \`${FLUID_AUDIO_DIR:-not run}\`

| File | Backend | Duration | Time | RTFx | Count | Status |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
EOF

printf "file\tbackend\tduration_seconds\telapsed_seconds\trtfx\tcount\tstatus\n" >"$SUMMARY"

for fixture in "${fixtures[@]}"; do
  stem="$(safe_stem "$fixture")"
  wav="$ARTIFACT_ROOT/audio/$stem.wav"
  duration="$(duration_seconds "$fixture")"

  echo "Preparing $fixture"
  run_logged "$ARTIFACT_ROOT/audio/$stem.ffmpeg.log" \
    "$FFMPEG_BIN" -y -hide_banner -loglevel error -i "$fixture" -vn -ac 1 -ar 16000 -f wav "$wav"

  if [[ "$RUN_WHISPER" -eq 1 ]]; then
    echo "Running Whisper on $stem"
    whisper_prefix="$ARTIFACT_ROOT/whisper/$stem"
    start="$(now_seconds)"
    run_status="ok"
    if ! run_logged "$whisper_prefix.log" \
      "$WHISPER_CLI_BIN" \
        -m "$WHISPER_MODEL_BIN" \
        -f "$wav" \
        -of "$whisper_prefix" \
        -oj \
        -pp \
        -ml 80 \
        -sow; then
      run_status="failed"
    fi
    end="$(now_seconds)"
    elapsed="$(elapsed_seconds "$start" "$end")"
    rtf="$(realtime_factor "$duration" "$elapsed")"
    count="$(json_segment_count "$whisper_prefix.json")"
    printf "| %s | Whisper | %s | %s | %s | %s | %s |\n" "$(basename "$fixture")" "$duration" "$elapsed" "$rtf" "$count" "$run_status" >>"$REPORT"
    printf "%s\tWhisper\t%s\t%s\t%s\t%s\t%s\n" "$(basename "$fixture")" "$duration" "$elapsed" "$rtf" "$count" "$run_status" >>"$SUMMARY"
  fi

  if [[ "$RUN_PARAKEET" -eq 1 ]]; then
      echo "Running Parakeet on $stem"
    parakeet_json="$ARTIFACT_ROOT/parakeet/$stem.json"
    parakeet_text="$ARTIFACT_ROOT/parakeet/$stem.txt"
    parakeet_log="$ARTIFACT_ROOT/parakeet/$stem.log"
    start="$(now_seconds)"
    run_status="ok"
    (
      "$PARAKEET_HELPER_BIN" "$wav" --model-version v2 --model-dir "$PARAKEET_MODEL_DIR" --output-json "$parakeet_json"
    ) >"$parakeet_text" 2>"$parakeet_log" || run_status="failed"
    end="$(now_seconds)"
    elapsed="$(elapsed_seconds "$start" "$end")"
    rtf="$(realtime_factor "$duration" "$elapsed")"
    count="$(json_segment_count "$parakeet_json")"
    if [[ "$count" == "n/a" ]]; then
      count="$(line_count "$parakeet_text")"
    fi
    printf "| %s | Parakeet | %s | %s | %s | %s | %s |\n" "$(basename "$fixture")" "$duration" "$elapsed" "$rtf" "$count" "$run_status" >>"$REPORT"
    printf "%s\tParakeet\t%s\t%s\t%s\t%s\t%s\n" "$(basename "$fixture")" "$duration" "$elapsed" "$rtf" "$count" "$run_status" >>"$SUMMARY"
  fi
done

cat >>"$REPORT" <<EOF

## Outputs

- Summary TSV: \`$SUMMARY\`
- Normalized WAVs: \`$ARTIFACT_ROOT/audio/\`
- Whisper outputs: \`$ARTIFACT_ROOT/whisper/\`
- Parakeet outputs: \`$ARTIFACT_ROOT/parakeet/\`
EOF

echo "Benchmark complete: $REPORT"
