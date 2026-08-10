#!/usr/bin/env python3

import argparse
import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DOCS = ROOT / "Documentation"
DEFAULT_SITE = ROOT / "website" / "help" / "index.html"
DEFAULT_APP_JSON = ROOT / ".build" / "help" / "help-content.json"


class DocumentationError(Exception):
    pass


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    if not slug:
        raise DocumentationError(f"Could not create an anchor for {value!r}")
    return slug


def render_inline(value: str) -> str:
    parts = re.split(r"(`[^`]+`)", value)
    return "".join(
        f"<kbd>{html.escape(part[1:-1])}</kbd>" if part.startswith("`") and part.endswith("`") else html.escape(part)
        for part in parts
    )


def plain_inline(value: str) -> str:
    return re.sub(r"`([^`]+)`", r"\1", value)


def parse_scalar(value: str):
    value = value.strip()
    if value.lower() in {"true", "false"}:
        return value.lower() == "true"
    if re.fullmatch(r"\d+", value):
        return int(value)
    return value


def parse_topic(path: Path) -> dict:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        raise DocumentationError(f"{path}: missing front matter")
    try:
        end = lines.index("---", 1)
    except ValueError as error:
        raise DocumentationError(f"{path}: unterminated front matter") from error

    metadata = {}
    for line_number, line in enumerate(lines[1:end], start=2):
        if not line.strip():
            continue
        if ":" not in line:
            raise DocumentationError(f"{path}:{line_number}: expected key: value")
        key, value = line.split(":", 1)
        metadata[key.strip()] = parse_scalar(value)

    required = {"id", "title", "summary", "symbol", "order"}
    missing = required - metadata.keys()
    if missing:
        raise DocumentationError(f"{path}: missing metadata: {', '.join(sorted(missing))}")

    sections = []
    current = None
    paragraph_lines = []

    def flush_paragraph():
        nonlocal paragraph_lines
        if paragraph_lines:
            if current is None:
                raise DocumentationError(f"{path}: content must follow a ## heading")
            current["paragraphs"].append(" ".join(part.strip() for part in paragraph_lines))
            paragraph_lines = []

    for line_number, line in enumerate(lines[end + 1 :], start=end + 2):
        stripped = line.strip()
        if stripped.count("`") % 2:
            raise DocumentationError(f"{path}:{line_number}: unmatched inline-code delimiter")
        if not stripped:
            flush_paragraph()
            continue
        if stripped.startswith("# "):
            raise DocumentationError(f"{path}:{line_number}: topic title belongs in front matter")
        if stripped.startswith("## "):
            flush_paragraph()
            title = stripped[3:].strip()
            current = {
                "id": slugify(title),
                "title": title,
                "paragraphs": [],
                "bullets": [],
                "steps": [],
                "note": None,
            }
            sections.append(current)
            continue
        if current is None:
            raise DocumentationError(f"{path}:{line_number}: content must follow a ## heading")
        if stripped.startswith("> **Note:**"):
            flush_paragraph()
            if current["note"] is not None:
                raise DocumentationError(f"{path}:{line_number}: section has more than one note")
            current["note"] = stripped.removeprefix("> **Note:**").strip()
            continue
        if stripped.startswith("- "):
            flush_paragraph()
            current["bullets"].append(stripped[2:].strip())
            continue
        step = re.match(r"^\d+\.\s+(.+)$", stripped)
        if step:
            flush_paragraph()
            current["steps"].append(step.group(1).strip())
            continue
        if stripped.startswith(("###", ">", "* ")):
            raise DocumentationError(f"{path}:{line_number}: unsupported Markdown construct")
        paragraph_lines.append(stripped)

    flush_paragraph()
    if not sections:
        raise DocumentationError(f"{path}: no sections found")
    section_ids = [section["id"] for section in sections]
    if len(section_ids) != len(set(section_ids)):
        raise DocumentationError(f"{path}: section headings must create unique anchors")

    return {
        "id": str(metadata["id"]),
        "title": str(metadata["title"]),
        "summary": str(metadata["summary"]),
        "symbolName": str(metadata["symbol"]),
        "order": int(metadata["order"]),
        "includeShortcuts": bool(metadata.get("shortcuts", False)),
        "sections": sections,
        "shortcutGroups": [],
        "source": path.name,
    }


def parse_shortcuts(path: Path) -> list[dict]:
    source = path.read_text(encoding="utf-8")
    definitions = {}
    definition_pattern = re.compile(
        r"static let\s+(\w+)\s*=\s*AppShortcutDefinition\("
        r"\s*id:\s*\"([^\"]+)\",\s*action:\s*\"([^\"]+)\",\s*keys:\s*\[([^\]]*)\]",
        re.MULTILINE,
    )
    for variable, shortcut_id, action, raw_keys in definition_pattern.findall(source):
        try:
            keys = json.loads(f"[{raw_keys}]")
        except json.JSONDecodeError as error:
            raise DocumentationError(f"Could not parse keys for shortcut {variable}") from error
        definitions[variable] = {"id": shortcut_id, "action": action, "keys": keys}

    catalog_match = re.search(
        r"static let helpGroups: \[AppShortcutGroupDefinition\] = \[(.*?)\n    \]\n}",
        source,
        re.DOTALL,
    )
    if not catalog_match:
        raise DocumentationError("Could not locate AppShortcutCatalog.helpGroups")

    group_pattern = re.compile(
        r"AppShortcutGroupDefinition\(\s*id:\s*\"([^\"]+)\",\s*title:\s*\"([^\"]+)\",\s*items:\s*\[([^\]]+)\]\s*\)",
        re.DOTALL,
    )
    groups = []
    for group_id, title, raw_items in group_pattern.findall(catalog_match.group(1)):
        names = [name.strip() for name in raw_items.split(",") if name.strip()]
        missing = [name for name in names if name not in definitions]
        if missing:
            raise DocumentationError(f"Unknown shortcuts in group {group_id}: {', '.join(missing)}")
        groups.append({"id": group_id, "title": title, "items": [definitions[name] for name in names]})
    if not groups:
        raise DocumentationError("No shortcut groups found")
    return groups


def load_documentation(docs_dir: Path) -> dict:
    paths = sorted(path for path in docs_dir.glob("*.md") if path.name.lower() != "readme.md")
    if not paths:
        raise DocumentationError(f"No documentation topics found in {docs_dir}")
    topics = [parse_topic(path) for path in paths]
    topic_ids = [topic["id"] for topic in topics]
    if len(topic_ids) != len(set(topic_ids)):
        raise DocumentationError("Documentation topic IDs must be unique")
    orders = [topic["order"] for topic in topics]
    if len(orders) != len(set(orders)):
        raise DocumentationError("Documentation topic order values must be unique")
    topics.sort(key=lambda topic: topic["order"])
    shortcut_topics = [topic for topic in topics if topic["includeShortcuts"]]
    if len(shortcut_topics) != 1:
        raise DocumentationError("Exactly one topic must declare shortcuts: true")
    shortcut_topics[0]["shortcutGroups"] = parse_shortcuts(ROOT / "src" / "AppCoreTypes.swift")
    for topic in topics:
        topic.pop("includeShortcuts", None)
        topic.pop("source", None)
    return {"schemaVersion": 1, "topics": topics}


def section_html(topic_id: str, section: dict) -> str:
    section_id = f"{topic_id}-{section['id']}"
    parts = [f'<section class="help-article-section" id="{html.escape(section_id)}">', f"<h2>{render_inline(section['title'])}</h2>"]
    parts.extend(f"<p>{render_inline(paragraph)}</p>" for paragraph in section["paragraphs"])
    if section["steps"]:
        parts.append("<ol>")
        parts.extend(f"<li>{render_inline(step)}</li>" for step in section["steps"])
        parts.append("</ol>")
    if section["bullets"]:
        parts.append("<ul>")
        parts.extend(f"<li>{render_inline(bullet)}</li>" for bullet in section["bullets"])
        parts.append("</ul>")
    if section["note"]:
        parts.append(f'<aside class="help-note"><strong>Note</strong><p>{render_inline(section["note"])}</p></aside>')
    parts.append(f'<a class="section-anchor" href="#{html.escape(section_id)}" aria-label="Link to {html.escape(section["title"])}">#</a>')
    parts.append("</section>")
    return "\n".join(parts)


def shortcut_html(groups: list[dict]) -> str:
    parts = []
    for group in groups:
        parts.append(f'<section class="shortcut-group" id="shortcuts-{html.escape(group["id"])}">')
        parts.append(f"<h2>{html.escape(group['title'])}</h2>")
        parts.append('<dl class="shortcut-list">')
        for item in group["items"]:
            keys = "".join(f"<kbd>{html.escape(key)}</kbd>" for key in item["keys"])
            parts.append(f'<div><dt>{html.escape(item["action"])}</dt><dd>{keys}</dd></div>')
        parts.append("</dl></section>")
    return "\n".join(parts)


def render_site(documentation: dict) -> str:
    topics = documentation["topics"]
    nav = "\n".join(
        f'<a class="help-topic-link" href="#{html.escape(topic["id"])}" data-topic="{html.escape(topic["id"])}">'
        f'<span>{html.escape(topic["title"])}</span><small>{html.escape(topic["summary"])}</small></a>'
        for topic in topics
    )
    options = "\n".join(
        f'<option value="{html.escape(topic["id"])}">{html.escape(topic["title"])}</option>' for topic in topics
    )
    articles = []
    for index, topic in enumerate(topics):
        article_parts = [
            f'<article class="help-article{" is-active" if index == 0 else ""}" data-topic="{html.escape(topic["id"])}" id="{html.escape(topic["id"])}">',
            '<header class="help-article-header">',
            f'<p class="help-overline">In/Out Help</p><h1>{html.escape(topic["title"])}</h1>',
            f'<p>{html.escape(topic["summary"])}</p></header>',
        ]
        article_parts.extend(section_html(topic["id"], section) for section in topic["sections"])
        if topic["shortcutGroups"]:
            article_parts.append(shortcut_html(topic["shortcutGroups"]))
        previous_topic = topics[index - 1] if index > 0 else None
        next_topic = topics[index + 1] if index + 1 < len(topics) else None
        article_parts.append('<nav class="article-pagination" aria-label="Documentation topics">')
        if previous_topic:
            article_parts.append(f'<a href="#{html.escape(previous_topic["id"])}">← {html.escape(previous_topic["title"])}</a>')
        else:
            article_parts.append("<span></span>")
        if next_topic:
            article_parts.append(f'<a href="#{html.escape(next_topic["id"])}">{html.escape(next_topic["title"])} →</a>')
        article_parts.append("</nav></article>")
        articles.append("\n".join(article_parts))

    search_data = [
        {
            "id": topic["id"],
            "title": topic["title"],
            "summary": topic["summary"],
            "text": " ".join(
                [topic["title"], topic["summary"]]
                + [
                    value
                    for section in topic["sections"]
                    for value in [plain_inline(section["title"]), *map(plain_inline, section["paragraphs"]), *map(plain_inline, section["bullets"]), *map(plain_inline, section["steps"]), plain_inline(section["note"] or "")]
                ]
                + [item["action"] for group in topic["shortcutGroups"] for item in group["items"]]
            ),
        }
        for topic in topics
    ]
    encoded_search = json.dumps(search_data, ensure_ascii=False).replace("</", "<\\/")
    return f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>In/Out Help</title>
  <meta name="description" content="Complete documentation for In/Out for macOS." />
  <link rel="icon" href="../assets/icon.png" />
  <link rel="stylesheet" href="../styles.css" />
  <link rel="stylesheet" href="./help.css" />
</head>
<body class="help-page">
  <div class="page-bg"></div>
  <header class="help-site-header">
    <a class="brand" href="../index.html" aria-label="In/Out home"><img src="../assets/icon.png" alt="" class="brand-icon" /><span class="brand-name">In/Out</span></a>
    <nav><a href="../index.html">Overview</a><a href="../index.html#download">Download</a></nav>
  </header>
  <div class="help-mobile-controls">
    <label for="help-topic-select">Help topic</label>
    <select id="help-topic-select">{options}</select>
    <label for="help-search-mobile">Search Help</label>
    <input id="help-search-mobile" data-help-search type="search" placeholder="Search Help" autocomplete="off" />
    <p class="help-search-status" data-help-search-status aria-live="polite"></p>
  </div>
  <main class="help-layout">
    <aside class="help-sidebar">
      <label class="help-search-label" for="help-search">Search Help</label>
      <input id="help-search" data-help-search type="search" placeholder="Search Help" autocomplete="off" />
      <p id="help-search-status" class="help-search-status" data-help-search-status aria-live="polite"></p>
      <nav class="help-topic-nav" aria-label="Help topics">{nav}</nav>
    </aside>
    <div class="help-content">{"".join(articles)}</div>
  </main>
  <footer class="help-footer"><a href="../index.html">In/Out for macOS</a><a href="https://github.com/chrisgherbert/inout/releases" target="_blank" rel="noopener noreferrer">Release History</a></footer>
  <script id="help-search-data" type="application/json">{encoded_search}</script>
  <script src="./help.js"></script>
</body>
</html>
'''


def serialized_documentation(documentation: dict) -> str:
    return json.dumps(documentation, ensure_ascii=False, indent=2) + "\n"


def write_or_check(path: Path, content: str, check: bool, label: str):
    if check:
        if not path.exists() or path.read_text(encoding="utf-8") != content:
            raise DocumentationError(f"Generated {label} is stale: {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate native and website Help content")
    parser.add_argument("--docs", type=Path, default=DEFAULT_DOCS)
    parser.add_argument("--site-output", type=Path, default=DEFAULT_SITE)
    parser.add_argument("--app-json", type=Path, default=DEFAULT_APP_JSON)
    parser.add_argument("--skip-site", action="store_true")
    parser.add_argument("--skip-app", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    try:
        documentation = load_documentation(args.docs)
        if not args.skip_site:
            write_or_check(args.site_output, render_site(documentation), args.check, "website Help")
        if not args.skip_app and not args.check:
            write_or_check(args.app_json, serialized_documentation(documentation), False, "app Help JSON")
    except DocumentationError as error:
        print(f"Documentation generation failed: {error}", file=sys.stderr)
        return 1

    mode = "validated" if args.check else "generated"
    print(f"Documentation {mode}: {len(documentation['topics'])} topics")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
