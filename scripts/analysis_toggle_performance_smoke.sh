#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VIEW_MODEL="$ROOT_DIR/src/WorkspaceViewModel.swift"
TOOL_VIEWS="$ROOT_DIR/src/ToolViews.swift"
PRESENTATION_MODELS="$ROOT_DIR/src/WorkspacePresentationModels.swift"

if rg -q '@Published var analyze(BlackFrames|BadEdits|AudioSilence|Profanity)' "$VIEW_MODEL"; then
  echo "Analysis toggles must not publish through WorkspaceViewModel."
  exit 1
fi

rg -q 'let analysisCheckPreferences = AnalysisCheckPreferencesModel\(\)' "$VIEW_MODEL"
rg -q '@ObservedObject var preferences: AnalysisCheckPreferencesModel' "$TOOL_VIEWS"
rg -q 'final class AnalysisCheckPreferencesModel: ObservableObject' "$PRESENTATION_MODELS"

echo "Analysis toggle isolation smoke test passed."
