#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${FFMPEG_BUILD_ROOT:-$ROOT_DIR/.build/ffmpeg-source}"
SRC_CACHE_DIR="$BUILD_ROOT/src"
WORK_DIR="$BUILD_ROOT/work"
OUT_DIR="${FFMPEG_OUT_DIR:-$ROOT_DIR/vendor/ffmpeg/macos-arm64}"
FFMPEG_VERSION="${FFMPEG_VERSION:-7.1.1}"
JOBS="${FFMPEG_JOBS:-$(sysctl -n hw.ncpu)}"
MIN_MACOS="${FFMPEG_MIN_MACOS:-12.0}"

# Optional: pass additional configure flags for external libs.
# Example:
#   FFMPEG_EXTRA_CONFIGURE_FLAGS="--enable-libass --enable-libx264 --enable-libmp3lame"
FFMPEG_EXTRA_CONFIGURE_FLAGS="${FFMPEG_EXTRA_CONFIGURE_FLAGS:-}"

mkdir -p "$SRC_CACHE_DIR" "$WORK_DIR" "$OUT_DIR"

TARBALL="$SRC_CACHE_DIR/ffmpeg-$FFMPEG_VERSION.tar.xz"
SRC_TREE="$WORK_DIR/ffmpeg-$FFMPEG_VERSION"

if [[ ! -f "$TARBALL" ]]; then
  echo "Downloading ffmpeg-$FFMPEG_VERSION source..."
  curl -fL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$TARBALL"
fi

rm -rf "$SRC_TREE"
tar -xf "$TARBALL" -C "$WORK_DIR"
cd "$SRC_TREE"

export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
export CFLAGS="-O3 -arch arm64 -mmacosx-version-min=$MIN_MACOS"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS"

CONFIGURE_ARGS=(
  --arch=arm64
  --target-os=darwin
  --cc=clang
  --cxx=clang++
  --enable-cross-compile
  --enable-pthreads
  --disable-debug
  --disable-doc
  --disable-ffplay
  --disable-ffprobe
  --enable-ffmpeg
  --enable-static
  --disable-shared
  --enable-avfoundation
  --enable-audiotoolbox
  --enable-videotoolbox
  --enable-filter=aresample,atrim,scale,volume,afade,alimiter
  --enable-protocol=file,pipe
)

if [[ -n "$FFMPEG_EXTRA_CONFIGURE_FLAGS" ]]; then
  # shellcheck disable=SC2206
  EXTRA_ARGS=(${=FFMPEG_EXTRA_CONFIGURE_FLAGS})
  CONFIGURE_ARGS+=("${EXTRA_ARGS[@]}")
fi

if [[ "$FFMPEG_EXTRA_CONFIGURE_FLAGS" == *"--enable-libass"* ]]; then
  CONFIGURE_ARGS+=(--enable-filter=subtitles)
fi

echo "Configuring ffmpeg source build..."
./configure "${CONFIGURE_ARGS[@]}"

echo "Building ffmpeg..."
make -j"$JOBS" ffmpeg

cp ffmpeg "$OUT_DIR/ffmpeg"
chmod +x "$OUT_DIR/ffmpeg"
shasum -a 256 "$OUT_DIR/ffmpeg" | awk '{print $1 "  ffmpeg"}' > "$OUT_DIR/ffmpeg.sha256"

"$ROOT_DIR/scripts/ffmpeg_dependency_audit.sh" "$OUT_DIR/ffmpeg"

echo "Built source ffmpeg:"
echo "  $OUT_DIR/ffmpeg"
echo "Checksum:"
echo "  $OUT_DIR/ffmpeg.sha256"
echo ""
echo "Tip:"
echo "  If you need extra codecs/filters, set FFMPEG_EXTRA_CONFIGURE_FLAGS and ensure deps are available."
echo "  Burned-in SRT subtitles require --enable-libass (and libass toolchain deps)."
