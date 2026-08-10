#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ANALYSIS_SOURCE="$ROOT_DIR/src-core/AnalysisDetection.swift"
PROFANITY_SOURCE="$ROOT_DIR/src-core/ParakeetTranscription.swift"

if grep -q 'transcribeAudioWithWhisper' "$ANALYSIS_SOURCE"; then
  echo "Profanity backend smoke test failed: AnalysisDetection still invokes Whisper." >&2
  exit 1
fi

if ! sed -n '/func detectProfanityHits(/,/^}/p' "$PROFANITY_SOURCE" | grep -q 'transcribeAudioWithParakeet'; then
  echo "Profanity backend smoke test failed: uncached profanity detection does not invoke Parakeet." >&2
  exit 1
fi

if ! sed -n '/if detectProfanity {/,/progressHandler(1.0)/p' "$ANALYSIS_SOURCE" | grep -q 'transcribeAudioWithParakeet'; then
  echo "Profanity backend smoke test failed: analysis fallback does not invoke Parakeet." >&2
  exit 1
fi

echo "Profanity transcription backend smoke test passed."
