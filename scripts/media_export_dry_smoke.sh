#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

require_text() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Fq "$pattern" "$file"; then
    echo "$message" >&2
    exit 1
  fi
}

require_text "$ROOT_DIR/src/ClipOutputPanel.swift" \
  "AdvancedVideoExportOptions(model: model" \
  "Clip Advanced export must use the shared video options."
require_text "$ROOT_DIR/src/ToolViews.swift" \
  "AdvancedVideoExportOptions(model: model" \
  "Convert video export must use the shared video options."
require_text "$ROOT_DIR/src/MediaExportOptionsViews.swift" \
  "MediaFramingOptionsButton(model: model)" \
  "Shared Advanced video options must expose media framing."
require_text "$ROOT_DIR/src/ClipOutputPanel.swift" \
  "AudioOnlyExportOptions(model: model)" \
  "Clip Audio Only export must use the shared audio options."
require_text "$ROOT_DIR/src/ToolViews.swift" \
  "AudioOnlyExportOptions(model: model)" \
  "Convert audio export must use the shared audio options."
require_text "$ROOT_DIR/src/WorkspaceViewModel+ClipExport.swift" \
  "let config = configOverride ?? queuedClipExportConfigSnapshot()" \
  "Exports must run from an immutable configuration snapshot."
require_text "$ROOT_DIR/src/WorkspaceViewModel+Queue.swift" \
  "clipFramingAspectRatio: clipFramingAspectRatio" \
  "Queued exports must snapshot framing settings."
require_text "$ROOT_DIR/src/WorkspaceViewModel+Queue.swift" \
  "clipFramingCustomCropX: clipFramingCustomCropX" \
  "Queued exports must snapshot custom crop coordinates."
require_text "$ROOT_DIR/src/WorkspaceViewModel+Queue.swift" \
  "clipFramingCustomCropY: clipFramingCustomCropY" \
  "Queued exports must snapshot both custom crop coordinates."
require_text "$ROOT_DIR/src/WorkspaceViewModel+Queue.swift" \
  "isFullSourceConversion: true" \
  "Whole-source conversion must be represented explicitly."
require_text "$ROOT_DIR/src/WorkspaceViewModel+ClipExport.swift" \
  "destination.standardizedFileURL != sourceURL.standardizedFileURL" \
  "Whole-source export must never replace its input file."

if grep -Eq 'self\.clip(Start|End)Seconds' "$ROOT_DIR/src/WorkspaceViewModel+ClipExport.swift"; then
  echo "The export task must not read the live Clip range after it starts." >&2
  exit 1
fi

echo "Media export DRY smoke test passed"
