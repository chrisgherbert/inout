#!/bin/zsh
set -euo pipefail

NOTES_PATH="${1:-}"

if [[ -z "$NOTES_PATH" || ! -s "$NOTES_PATH" ]]; then
  echo "Release notes not found or empty: ${NOTES_PATH:-<missing path>}"
  exit 1
fi

if grep -Eq '^(#+[[:space:]]+)?(Artifacts|Build metadata):[[:space:]]*$' "$NOTES_PATH"; then
  echo "Release notes contain internal artifact or build metadata: $NOTES_PATH"
  exit 1
fi

if ! grep -Eq '[[:alnum:]]' "$NOTES_PATH"; then
  echo "Release notes do not contain user-facing text: $NOTES_PATH"
  exit 1
fi

echo "Release notes validated: $NOTES_PATH"
