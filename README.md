# Black Frame Checker (macOS)

Native macOS GUI app that performs black-frame detection with Apple media frameworks and shows results in a desktop interface.

## Requirements

- macOS
- Xcode Command Line Tools (`xcode-select --install`)

## Build

```bash
./scripts/build_app.sh
```

This creates:

- `dist/CheckBlackFrames.app`

## Run

- Double-click `dist/CheckBlackFrames.app`
- Choose a source video (`Choose Video`)
- You can also drag and drop a video directly into the app window
- Use the tool switcher:
  - `Analyze` for black-frame detection
  - `Convert` for audio export workflow
  - `Inspect` for quick source/result snapshot

## Behavior

- Uses native frame analysis with thresholds equivalent to:
  - minimum duration: `0.001s` (single-frame sensitive)
  - frame dark-area threshold: `pic_th=0.90`
  - pixel darkness threshold equivalent to ffmpeg default `pix_th=0.10`
- Emits segments like: `HH:MM:SS.mmm → HH:MM:SS.mmm (0.033s)`
- UI includes:
  - Modular tool layout with shared source header
  - Finder drag-and-drop target in the main window
  - Analyze tool with inline player and black-segment timeline/list
  - Convert tool with export controls (M4A active, MP3 scaffolded in UI)
  - Inspect tool for source/result snapshot
  - Unified activity panel with progress and output actions
