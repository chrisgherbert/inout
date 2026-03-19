#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT_DIR/dist/In-Out.app"
APP_EXE="$APP/Contents/MacOS/BulwarkVideoTools"
ARTIFACT_DIR="$ROOT_DIR/.artifacts/playhead-benchmark"
FIXTURE_DIR="$ARTIFACT_DIR/fixtures"
DEFAULT_FIXTURE="$FIXTURE_DIR/playhead-benchmark-fixture.mp4"
DEFAULT_OUTPUT="$ARTIFACT_DIR/latest.json"
DEFAULT_PROGRESS="$ARTIFACT_DIR/latest.progress.json"

MEDIA_PATH=""
OUTPUT_PATH="$DEFAULT_OUTPUT"
PROGRESS_PATH="$DEFAULT_PROGRESS"
BASELINE_PATH=""
SCENARIOS="slow_drag,fast_scrub,back_and_forth,edge_auto_pan"
TIMEOUT_SECONDS=120
SHOULD_BUILD=1

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --media PATH         Use an existing media file instead of the generated fixture.
  --output PATH        Write benchmark JSON to PATH.
  --baseline PATH      Compare the run against an existing benchmark JSON.
  --scenarios CSV      Override scenarios (comma-separated).
  --timeout SECONDS    Benchmark timeout. Default: ${TIMEOUT_SECONDS}
  --skip-build         Reuse the existing app build.
  --help               Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --media)
      MEDIA_PATH="$2"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="$2"
      PROGRESS_PATH="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).with_suffix(".progress.json"))' "$2")"
      shift 2
      ;;
    --baseline)
      BASELINE_PATH="$2"
      shift 2
      ;;
    --scenarios)
      SCENARIOS="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --skip-build)
      SHOULD_BUILD=0
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mkdir -p "$ARTIFACT_DIR" "$FIXTURE_DIR"

choose_ffmpeg() {
  local bundled="$APP/Contents/Resources/ffmpeg"
  if [[ -x "$bundled" ]]; then
    echo "$bundled"
    return
  fi
  if command -v ffmpeg >/dev/null 2>&1; then
    command -v ffmpeg
    return
  fi
  echo "ERROR: ffmpeg not found. Build the app first or install ffmpeg." >&2
  exit 1
}

generate_fixture() {
  local ffmpeg_bin="$1"
  local fixture="$2"
  echo "Generating benchmark fixture at $fixture"
  "$ffmpeg_bin" -y \
    -f lavfi -i "testsrc2=size=1280x720:rate=30" \
    -f lavfi -i "sine=frequency=220:sample_rate=48000:duration=240" \
    -f lavfi -i "anoisesrc=color=pink:sample_rate=48000:duration=240:amplitude=0.10" \
    -filter_complex "[1:a][2:a]amix=inputs=2:weights='1 0.35',volume=0.9[aout]" \
    -map 0:v:0 -map "[aout]" \
    -t 240 \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    -c:a aac -b:a 160k \
    "$fixture" >/dev/null 2>&1
}

if (( SHOULD_BUILD )); then
  echo "Building app (dev)..."
  "$ROOT_DIR/scripts/build_app.sh" dev >/dev/null
fi

if [[ ! -x "$APP_EXE" ]]; then
  echo "ERROR: app executable not found at $APP_EXE" >&2
  exit 1
fi

if [[ -z "$MEDIA_PATH" ]]; then
  if [[ ! -f "$DEFAULT_FIXTURE" ]]; then
    generate_fixture "$(choose_ffmpeg)" "$DEFAULT_FIXTURE"
  fi
  MEDIA_PATH="$DEFAULT_FIXTURE"
fi

if [[ ! -f "$MEDIA_PATH" ]]; then
  echo "ERROR: media file not found at $MEDIA_PATH" >&2
  exit 1
fi

rm -f "$OUTPUT_PATH"
rm -f "$PROGRESS_PATH"

echo "Running playhead benchmark against $MEDIA_PATH"
INOUT_PLAYHEAD_BENCHMARK=1 \
INOUT_PLAYHEAD_BENCHMARK_OUTPUT="$OUTPUT_PATH" \
INOUT_PLAYHEAD_BENCHMARK_PROGRESS_OUTPUT="$PROGRESS_PATH" \
INOUT_PLAYHEAD_BENCHMARK_EXIT=1 \
INOUT_PLAYHEAD_BENCHMARK_SCENARIOS="$SCENARIOS" \
"$APP_EXE" "$MEDIA_PATH" >/dev/null 2>&1 &
APP_PID=$!

SECONDS_WAITED=0
while kill -0 "$APP_PID" 2>/dev/null; do
  if [[ -f "$OUTPUT_PATH" ]]; then
    break
  fi
  if (( SECONDS_WAITED >= TIMEOUT_SECONDS )); then
    echo "ERROR: benchmark timed out after ${TIMEOUT_SECONDS}s" >&2
    if [[ -f "$PROGRESS_PATH" ]]; then
      echo "Last benchmark progress:" >&2
      cat "$PROGRESS_PATH" >&2
    fi
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
    exit 1
  fi
  sleep 1
  ((SECONDS_WAITED += 1))
done

wait "$APP_PID"

if [[ ! -f "$OUTPUT_PATH" ]]; then
  echo "ERROR: benchmark did not produce output at $OUTPUT_PATH" >&2
  exit 1
fi

python3 - "$OUTPUT_PATH" "$BASELINE_PATH" <<'PY'
import json
import math
import pathlib
import sys

output_path = pathlib.Path(sys.argv[1])
baseline_path = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None

with output_path.open() as f:
    data = json.load(f)

baseline = None
if baseline_path and baseline_path.exists():
    with baseline_path.open() as f:
        baseline = json.load(f)


def scenario_map(doc):
    return {item["name"]: item for item in doc.get("scenarios", [])}


def metric(doc):
    scenarios = doc.get("scenarios", [])
    if not scenarios:
        return {}
    def avg(values):
        values = [v for v in values if v is not None]
        return sum(values) / len(values) if values else None
    return {
        "avg_input_to_visual_p95_ms": avg([s.get("inputToVisualLatency", {}).get("p95Ms") if s.get("inputToVisualLatency") else None for s in scenarios]),
        "avg_visual_interval_p95_ms": avg([s.get("visualInterval", {}).get("p95Ms") if s.get("visualInterval") else None for s in scenarios]),
        "avg_main_thread_p95_ms": avg([s.get("mainThreadPulse", {}).get("p95Ms") if s.get("mainThreadPulse") else None for s in scenarios]),
        "total_stalls_over_25ms": sum(s.get("mainThreadStallsOver25Ms", 0) for s in scenarios),
        "mini_map_per_second": avg([s.get("miniMapBodyEvaluations", {}).get("perSecond") for s in scenarios]),
        "utility_row_per_second": avg([s.get("utilityRowBodyEvaluations", {}).get("perSecond") for s in scenarios]),
        "selection_panel_per_second": avg([s.get("selectionPanelBodyEvaluations", {}).get("perSecond") for s in scenarios]),
        "full_timeline_updates_per_second": avg([s.get("fullTimelineUpdates", {}).get("perSecond") for s in scenarios]),
        "model_writes_per_second": avg([
            (sum(s.get("modelWrites", {}).values()) / max(0.001, s.get("durationMs", 1) / 1000.0))
            for s in scenarios
        ]),
    }


def fmt(value):
    if value is None:
        return "n/a"
    if isinstance(value, int):
        return str(value)
    return f"{value:.2f}"

current_metrics = metric(data)
print(f"Playhead benchmark summary: {output_path}")
print()
for scenario in data.get("scenarios", []):
    latency = scenario.get("inputToVisualLatency") or {}
    visual = scenario.get("visualInterval") or {}
    pulse = scenario.get("mainThreadPulse") or {}
    print(
        f"- {scenario['name']}: latency p95 {fmt(latency.get('p95Ms'))} ms, "
        f"visual interval p95 {fmt(visual.get('p95Ms'))} ms, "
        f"main-thread pulse p95 {fmt(pulse.get('p95Ms'))} ms, "
        f"stalls>25ms {scenario.get('mainThreadStallsOver25Ms', 0)}, "
        f"mini-map {fmt(scenario.get('miniMapBodyEvaluations', {}).get('perSecond'))}/s, "
        f"utility row {fmt(scenario.get('utilityRowBodyEvaluations', {}).get('perSecond'))}/s, "
        f"selection panel {fmt(scenario.get('selectionPanelBodyEvaluations', {}).get('perSecond'))}/s"
    )

print()
print("Aggregate proxies:")
for key, value in current_metrics.items():
    print(f"  {key}: {fmt(value)}")

if baseline:
    print()
    print(f"Comparison vs baseline: {baseline_path}")
    baseline_metrics = metric(baseline)
    for key, value in current_metrics.items():
        previous = baseline_metrics.get(key)
        if value is None or previous is None:
            delta = "n/a"
        else:
            change = value - previous
            sign = "+" if change >= 0 else ""
            delta = f"{sign}{change:.2f}"
        print(f"  {key}: {fmt(previous)} -> {fmt(value)} ({delta})")
PY

echo
echo "Benchmark JSON written to $OUTPUT_PATH"
