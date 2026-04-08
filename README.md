# In/Out (macOS)

Simple clipping, converting, and QA testing of video/audio files on macOS.

## For Users

- Website: [https://chrisgherbert.github.io/inout/](https://chrisgherbert.github.io/inout/)
- Releases: [GitHub Releases](https://github.com/chrisgherbert/inout/releases)

### System Requirements

- macOS 13 Ventura or later
- Apple Silicon Mac

### What It Does

- Clip media with In/Out points and marker navigation
- Export clips quickly or with advanced options
- Export audio-only files
- Open source media from URL (YouTube, TikTok, and more) via bundled `yt-dlp`
- Analyze for:
  - black segments
  - silent gaps
  - optional transcript/profanity checks
- Inspect technical metadata (codec, bitrate, frame rate, resolution, etc.)

### Basic Usage

1. Download and open the `In-Out` installer DMG.
2. Drag `In-Out.app` into your `Applications` folder.
3. Launch `In-Out` from `Applications`.
4. Load source media:
   - choose a local media file (or drag/drop one into the window), or
   - use `File > Download Media from URL…` to import from a web link.
5. Pick a tool tab:
   - `Clip`
   - `Analyze`
   - `Convert`
   - `Inspect`
6. Export or analyze from that tab.

### Notes

- Early build: validate outputs before production use.
- Audio export defaults:
  - `M4A` via AVFoundation
  - `MP3` via bundled `ffmpeg` (default 128 kbps)

## For Developers

### Dependencies

- macOS
- Xcode Command Line Tools (`xcode-select --install`)
- Bundled runtime tools for release:
  - `ffmpeg`
  - `ffprobe`
  - `yt-dlp`
  - `whisper-cli` + model
  - managed Python runtime release asset for downloader support

### Local Build

```bash
./scripts/build_app.sh
```

Build output:
- `dist/In-Out.app`

### Fast Iteration (No Release Overhead)

```bash
./scripts/dev_iterate.sh
```

Behavior:
- quick compile path
- no signing/notarization/release
- keeps bundled ffmpeg/whisper/model unchanged by default

Optional:

```bash
# re-copy bundled tools into app resources
./scripts/dev_iterate.sh --refresh-tools

# run portability/dependency checks against bundled tools
./scripts/dev_iterate.sh --verify-tools

# build and launch
./scripts/dev_iterate.sh --run
```

### Bundled ffmpeg Management

- Pin a deterministic ffmpeg binary:
  - `./scripts/pin_ffmpeg.sh /path/to/ffmpeg`
- Build ffmpeg from source into pinned vendor path:
  - `./scripts/build_ffmpeg_from_source.sh`
  - Optional extra codec/filter flags:
    - `FFMPEG_EXTRA_CONFIGURE_FLAGS="--enable-libass --enable-libx264 --enable-libmp3lame" ./scripts/build_ffmpeg_from_source.sh`

### Release Flow

- Release builds enforce pinned binary checks and portability audits.
- Notarization flow runs dependency audits + smoke tests before submission.

```bash
./scripts/notarize_release.sh
./scripts/github_release.sh --version X.Y.Z
```

Release artifacts:
- notarized installer DMG for users
- managed Python runtime tarball for downloader support
