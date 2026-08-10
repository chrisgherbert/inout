---
id: transcript
title: Work with transcripts
summary: Generate, search, format, select, copy, and export time-aligned transcript text.
symbol: captions.bubble
order: 4
---

## Generate a transcript

Open the transcript sidebar in Clip, then choose Generate Transcript. In/Out uses Parakeet for fast, word-timed transcription. Starting AI Suggestions before a transcript exists can generate it automatically first.

> **Note:** Wording and timing can move slightly while transcription is still in progress.

## Read and navigate

- Use the transcript View popover to switch between Compact Lines and Paragraphs, show or hide timecodes, and change text size.
- Choose View > Timecode Format to change timecodes throughout the app. Manage built-in and custom presets in the Timecodes section of Settings.
- Search for a word or phrase, then use the previous and next controls to move through matches.
- Click a transcript row to move the playhead. Double-click a row to begin playback there.
- During playback, the transcript follows the active row. Hiding the sidebar leaves the transcript available in the current window.

## Select and copy text

- `⌘`-click rows to add or remove individual rows from the selection.
- `⇧`-click to select a continuous range of rows.
- Press `⌘` `C` to copy the selected rows. Right-click a selected row to copy the selection, or an unselected row to copy only that row.
- Press `Escape` or click below the transcript rows to clear the selection.
- Copied rows include timecodes only when timecodes are visible.

## Export a transcript

- Choose Export in the transcript sidebar to select Text, Markdown, CSV, JSON, SRT, or WebVTT.
- Text and Markdown support Paragraphs, Compact Lines, or Continuous Text.
- Readable exports can omit timecodes or include start times or start-and-end times. Continuous Text never includes timecodes.

## Reopen saved transcripts

Completed transcripts are stored locally without copying the original video. Opening the same unchanged file restores its transcript automatically.

- Use Recent Transcripts on the opening screen or File > Open Recent Transcript to reopen a video with saved transcript data.
- Pin an entry to prevent automatic removal. Missing files can be located again from the entry's contextual menu.
- Settings > General controls transcript retention and provides Clear History. Modified video is treated as a different file and is transcribed again.
