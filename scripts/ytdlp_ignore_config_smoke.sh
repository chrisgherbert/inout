#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/In-Out.app}"
YTDLP_SCRIPT="${YTDLP_SCRIPT:-}"
PYTHON_BIN="${PYTHON_BIN:-}"
TEMP_ROOT=""

cleanup() {
  if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}
trap cleanup EXIT

if [[ -z "$YTDLP_SCRIPT" ]]; then
  app_script="$APP_PATH/Contents/Resources/yt-dlp"
  vendor_script="$ROOT_DIR/vendor/yt-dlp/macos-arm64/yt-dlp"
  if [[ -f "$app_script" ]]; then
    YTDLP_SCRIPT="$app_script"
  elif [[ -f "$vendor_script" ]]; then
    YTDLP_SCRIPT="$vendor_script"
  else
    echo "Unable to find yt-dlp script. Set YTDLP_SCRIPT=/path/to/yt-dlp." >&2
    exit 1
  fi
fi

TEMP_ROOT="$(mktemp -d)"

if [[ -z "$PYTHON_BIN" ]]; then
  app_python="$APP_PATH/Contents/Resources/PythonRuntime/current/bin/python3"
  support_python="$HOME/Library/Application Support/In-Out/Downloader/PythonRuntime/current/bin/python3"
  runtime_archive="$ROOT_DIR/dist/In-Out-python-runtime.tar.gz"

  if [[ -x "$app_python" ]]; then
    PYTHON_BIN="$app_python"
  elif [[ -x "$support_python" ]]; then
    PYTHON_BIN="$support_python"
  elif [[ -f "$runtime_archive" ]]; then
    runtime_extract="$TEMP_ROOT/runtime"
    mkdir -p "$runtime_extract"
    tar -xzf "$runtime_archive" -C "$runtime_extract"
    PYTHON_BIN="$runtime_extract/PythonRuntime/current/bin/python3"
  elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
  else
    echo "Unable to find python3. Set PYTHON_BIN=/path/to/python3." >&2
    exit 1
  fi
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "python3 is not executable: $PYTHON_BIN" >&2
  exit 1
fi

if [[ ! -f "$YTDLP_SCRIPT" ]]; then
  echo "yt-dlp script is missing: $YTDLP_SCRIPT" >&2
  exit 1
fi

PYTHON_HOME="$(cd "$(dirname "$PYTHON_BIN")/.." && pwd)"
MANAGED_LAUNCHER="$PYTHON_HOME/inout_ytdlp_launcher.py"
LAUNCH_ARGS=()
if [[ -f "$MANAGED_LAUNCHER" ]]; then
  LAUNCH_ARGS=(-S "$MANAGED_LAUNCHER")
fi

fake_home="$TEMP_ROOT/home"
poison_path="$TEMP_ROOT/poison-pythonpath"
bad_python_home="$TEMP_ROOT/bad-python-home"
mkdir -p "$fake_home/.config/yt-dlp" "$poison_path" "$bad_python_home"

cat > "$fake_home/.config/yt-dlp/config" <<'EOF'
--this-option-should-break-if-user-config-is-read
EOF

cat > "$poison_path/sitecustomize.py" <<'EOF'
raise SystemExit("PYTHONPATH leaked into managed yt-dlp invocation")
EOF

HOME="$fake_home" \
PYTHONNOUSERSITE=1 \
PYTHONPATH="$poison_path" \
PYTHONHOME="$bad_python_home" \
env -u PYTHONPATH -u PYTHONHOME \
  "$PYTHON_BIN" "${LAUNCH_ARGS[@]}" "$YTDLP_SCRIPT" --ignore-config --version >/dev/null

echo "yt-dlp ignore-config smoke test passed."
