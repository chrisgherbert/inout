# Release Notes

Add user-facing Markdown for each release as `vX.Y.Z.md`. The release script
uses this text for both the GitHub release description and Sparkle's update
window.

Focus on what changed for users. Do not include artifact names, checksums, or
build metadata; the release script verifies those separately.

Use a different file with `scripts/github_release.sh --notes-file PATH` when
needed.
