#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="${1:-$ROOT_DIR/dist/In-Out-python-runtime.tar.gz}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/inout-python-runtime-smoke.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

tar -xzf "$ARCHIVE" -C "$WORK_DIR"
HOME_DIR="$WORK_DIR/PythonRuntime/current"
PYTHON="$HOME_DIR/bin/python3"
LAUNCHER="$HOME_DIR/inout_ytdlp_launcher.py"

env -i \
  HOME="$WORK_DIR/home" \
  PATH="/usr/bin:/bin" \
  PYTHONNOUSERSITE=1 \
  "$PYTHON" -S "$LAUNCHER" --inout-check-runtime >/dev/null

OUTPUT="$(env -i HOME="$WORK_DIR/home" PATH="/usr/bin:/bin" PYTHONNOUSERSITE=1 \
  "$PYTHON" -S "$LAUNCHER" --inout-check-runtime)"
[[ "$OUTPUT" == "Managed Python dependencies ready" ]]

echo "Managed Python runtime smoke test passed without Homebrew or system Python paths."
