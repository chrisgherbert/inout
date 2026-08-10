# In/Out Documentation

These Markdown files are the canonical source for both the native Help window and the website documentation.

Supported article structure:

- YAML-style scalar front matter (`id`, `title`, `summary`, `symbol`, `order`, and optional `shortcuts`)
- `##` section headings
- paragraphs
- inline code spans for keyboard keys
- unordered lists beginning with `-`
- ordered steps beginning with `1.`
- notes beginning with `> **Note:**`

Run `./scripts/generate_help.py` after editing. The generator validates IDs, ordering, anchors, and structure, creates the website Help page, and writes the JSON bundled by the app build.
