#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VIEW_MODEL="$ROOT_DIR/src/WorkspaceViewModel.swift"
CORE_TYPES="$ROOT_DIR/src/AppCoreTypes.swift"
CLIP_EXPORT="$ROOT_DIR/src/WorkspaceViewModel+ClipExport.swift"
SOURCE_IMPORT="$ROOT_DIR/src/WorkspaceViewModel+SourceImport.swift"

rg -q '@Published var completionSound: CompletionSound = \.glass' "$VIEW_MODEL"
if rg -q 'case crystal|NSSound\.Name\("Crystal"\)' "$CORE_TYPES" "$VIEW_MODEL"; then
  echo "Unavailable Crystal sound must not be offered or played."
  exit 1
fi

rg -q 'let shouldPostNotification = !NSApp\.isActive' "$VIEW_MODEL"
rg -q 'playConfiguredCompletionSound\(\)' "$VIEW_MODEL"
rg -q 'center\.getNotificationSettings' "$VIEW_MODEL"

rg -q 'notifyCompletion\("Download Complete"' "$SOURCE_IMPORT"
rg -q 'notifyCompletion\("Download Failed".*outcome: \.failed' "$SOURCE_IMPORT"
rg -q 'notifyCompletion\("Clip Export Complete"' "$CLIP_EXPORT"
rg -q 'notifyCompletion\("Clip Export Failed".*outcome: \.failed' "$CLIP_EXPORT"

unexpected_sound_calls="$(
  rg -l 'completionSound\.soundName' "$ROOT_DIR/src" --glob '*.swift' |
    grep -v -E '/(PreferencesView|WorkspaceViewModel)\.swift$' || true
)"
if [[ -n "$unexpected_sound_calls" ]]; then
  echo "Completion sounds must be routed through WorkspaceViewModel.notifyCompletion:"
  echo "$unexpected_sound_calls"
  exit 1
fi

swift - <<'SWIFT'
import AppKit

for name in ["Glass", "Basso", "Funk"] {
    guard NSSound(named: NSSound.Name(name)) != nil else {
        fatalError("Configured completion sound is unavailable: \(name)")
    }
}
SWIFT

echo "Completion feedback smoke test passed."
