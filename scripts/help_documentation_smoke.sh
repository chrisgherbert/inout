#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/In-Out.app}"
BUNDLED_HELP="$APP_PATH/Contents/Resources/help-content.json"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/inout-help-smoke.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

if [[ ! -f "$BUNDLED_HELP" ]]; then
  echo "Help documentation smoke test failed: missing $BUNDLED_HELP" >&2
  exit 1
fi

"$ROOT_DIR/scripts/generate_help.py" \
  --skip-site \
  --app-json "$TEMP_DIR/help-content.json" >/dev/null
"$ROOT_DIR/scripts/generate_help.py" --check --skip-app >/dev/null

if ! cmp -s "$TEMP_DIR/help-content.json" "$BUNDLED_HELP"; then
  echo "Help documentation smoke test failed: bundled JSON is stale" >&2
  exit 1
fi

python3 - "$BUNDLED_HELP" "$ROOT_DIR/website/help/index.html" <<'PY'
import json
import sys
from html.parser import HTMLParser
from pathlib import Path

content_path = Path(sys.argv[1])
site_path = Path(sys.argv[2])
content = json.loads(content_path.read_text(encoding="utf-8"))
topics = content.get("topics", [])
if content.get("schemaVersion") != 1 or not topics:
    raise SystemExit("Help documentation smoke test failed: invalid schema")
if len({topic["id"] for topic in topics}) != len(topics):
    raise SystemExit("Help documentation smoke test failed: duplicate topic IDs")
if not any(topic.get("shortcutGroups") for topic in topics):
    raise SystemExit("Help documentation smoke test failed: shortcuts are missing")

class IDParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
    def handle_starttag(self, _tag, attrs):
        attributes = dict(attrs)
        if "id" in attributes:
            if attributes["id"] in self.ids:
                raise SystemExit(f"Help documentation smoke test failed: duplicate HTML ID {attributes['id']}")
            self.ids.add(attributes["id"])

parser = IDParser()
parser.feed(site_path.read_text(encoding="utf-8"))
missing = [topic["id"] for topic in topics if topic["id"] not in parser.ids]
if missing:
    raise SystemExit(f"Help documentation smoke test failed: missing website topics {missing}")
PY

echo "Help documentation smoke test passed (${BUNDLED_HELP})."
