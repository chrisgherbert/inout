#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
OUTPUT_ARCHIVE="${OUTPUT_ARCHIVE:-$DIST_DIR/In-Out-python-runtime.tar.gz}"
OUTPUT_SHA="$OUTPUT_ARCHIVE.sha256"
SOURCE_ARCHIVE="${SOURCE_ARCHIVE:-$OUTPUT_ARCHIVE}"
BUILD_PYTHON="${BUILD_PYTHON:-$(command -v python3)}"
REQUIREMENTS="$ROOT_DIR/scripts/python-runtime-requirements.txt"
LAUNCHER_SOURCE="$ROOT_DIR/scripts/managed_ytdlp_launcher.py"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/inout-python-runtime.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  echo "Source runtime archive not found: $SOURCE_ARCHIVE" >&2
  exit 1
fi
if [[ ! -x "$BUILD_PYTHON" ]]; then
  echo "Build Python is unavailable: $BUILD_PYTHON" >&2
  exit 1
fi

# Preserve the input when refreshing the archive in place.
SOURCE_COPY="$WORK_DIR/source-runtime.tar.gz"
cp "$SOURCE_ARCHIVE" "$SOURCE_COPY"
mkdir -p "$WORK_DIR/runtime"
tar -xzf "$SOURCE_COPY" -C "$WORK_DIR/runtime"

RUNTIME_ROOT="$WORK_DIR/runtime/PythonRuntime"
RUNTIME_HOME="$RUNTIME_ROOT/current"
RUNTIME_PYTHON="$RUNTIME_HOME/bin/python3"
if [[ ! -x "$RUNTIME_PYTHON" ]]; then
  echo "Runtime archive is missing PythonRuntime/current/bin/python3" >&2
  exit 1
fi

RUNTIME_MINOR="$($RUNTIME_PYTHON -S -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
BUILD_MINOR="$($BUILD_PYTHON -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
if [[ "$RUNTIME_MINOR" != "$BUILD_MINOR" ]]; then
  echo "Build Python $BUILD_MINOR does not match runtime Python $RUNTIME_MINOR." >&2
  exit 1
fi

SITE_PACKAGES="$RUNTIME_HOME/lib/python$RUNTIME_MINOR/site-packages"
if [[ -L "$SITE_PACKAGES" || -e "$SITE_PACKAGES" ]]; then
  rm -rf "$SITE_PACKAGES"
fi
mkdir -p "$SITE_PACKAGES"

echo "Installing app-owned Python dependencies into the portable runtime..."
"$BUILD_PYTHON" -m pip install \
  --disable-pip-version-check \
  --no-compile \
  --only-binary=:all: \
  --requirement "$REQUIREMENTS" \
  --target "$SITE_PACKAGES"

cp "$LAUNCHER_SOURCE" "$RUNTIME_HOME/inout_ytdlp_launcher.py"
chmod 755 "$RUNTIME_HOME/inout_ytdlp_launcher.py"

"$RUNTIME_PYTHON" -S "$RUNTIME_HOME/inout_ytdlp_launcher.py" --inout-check-runtime

"$RUNTIME_PYTHON" -S - "$RUNTIME_HOME" <<'PY'
import json
import os
import sys
from importlib.metadata import distributions

runtime_home = os.path.realpath(sys.argv[1])
version = f"python{sys.version_info.major}.{sys.version_info.minor}"
site_packages = os.path.join(runtime_home, "lib", version, "site-packages")
sys.path.insert(0, site_packages)
packages = {
    dist.metadata["Name"]: dist.version
    for dist in distributions(path=[site_packages])
    if dist.metadata.get("Name")
}
with open(os.path.join(runtime_home, "inout-runtime-dependencies.json"), "w", encoding="utf-8") as handle:
    json.dump({"python": sys.version.split()[0], "packages": dict(sorted(packages.items()))}, handle, indent=2)
    handle.write("\n")
PY

find "$RUNTIME_ROOT" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$RUNTIME_ROOT" -name '*.pyc' -delete

mkdir -p "$(dirname "$OUTPUT_ARCHIVE")"
rm -f "$OUTPUT_ARCHIVE" "$OUTPUT_SHA"
tar -czf "$OUTPUT_ARCHIVE" -C "$WORK_DIR/runtime" PythonRuntime
shasum -a 256 "$OUTPUT_ARCHIVE" > "$OUTPUT_SHA"

echo "Packaged managed Python runtime: $OUTPUT_ARCHIVE"
echo "Checksum: $OUTPUT_SHA"
