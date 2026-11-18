---
id: transcript
title: Work with transcripts
summary: Generate, search, format, select, copy, and export time-aligned transcript text.
symbol: captions.bubble
order: 4
---

## Generate a transcript

Open the transcript sidebar in Clip, then choose Generate Transcript. Transcription runs on your Mac and currently supports English. Starting AI Suggestions before a transcript exists can generate it automatically first.

> **Note:** Wording and timing can move slightly while transcription is still in progress.

## Read and navigate

- Use the transcript View popover to switch between Compact Lines and Paragraphs, show or hide timecodes, and change text size.
- Choose View > Timecode Format to change timecodes throughout the app. Manage built-in and custom presets in the Timecodes section of Settings.
- Search for a word or phrase. The match count and previous/next buttons appear inside the search field. Press Return for the next match or Shift-Return for the previous match.
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
- Hold `⌥` while choosing Export to save immediately beside the source video without opening a save dialog. The current format and layout options are used.

## Clean up a transcript

1. After transcription finishes, choose Clean Up in the transcript toolbar.
2. Choose a provider. Optionally add names or episode context to help with spelling.
3. Choose Start Cleanup. You can keep working while it runs; cancel from the activity area if needed.
4. Choose Review Corrections when results are ready. Play a passage to check it, then select and apply the changes you want. Apply All accepts every suggestion; Discard Results dismisses them.

Cleanup focuses on names and recognition errors while preserving the speaker's wording and original timing. Corrected text is used in transcript and caption exports. Review suggestions for accuracy.

> **Note:** Apple Intelligence runs locally. Cloud providers receive transcript text and any context you supply, using your API key. API usage is billed separately from consumer chat subscriptions.

## Quick Clean Up

Hold `⌥` and click Clean Up to run with your saved settings and automatically apply corrections. You can also choose Quick Clean Up in the cleanup popover. Use this when you do not need to review each suggestion first.

Pending corrections must be applied or discarded before starting another cleanup.

## Undo or restore the original

Choose Undo below the transcript after applying corrections. You can also open Clean Up and choose Undo Cleanup or Restore Original Transcript, including after reopening the video.

The original transcript is kept with the corrected version. Corrections preserve word timing, though caption line breaks may change.

## If cleanup needs attention

- Check the provider and model in the cleanup popover. Cloud providers need a working API key in Settings > AI.
- Add names or episode context if spellings are wrong, then run cleanup again.
- Some proposed changes may be skipped if they cannot be matched to the original text. Review the remaining suggestions in the Corrections tab.
- For a failed request, check Inspect > Console for the error. Remove private transcript text and credentials before sharing a report.

## Reopen saved transcripts

Completed transcripts are stored locally without copying the original video. Opening the same unchanged file restores its transcript automatically.

- Use Recent Transcripts on the opening screen or File > Open Recent Transcript to reopen a video with saved transcript data.
- Pin an entry to prevent automatic removal. Missing files can be located again from the entry's contextual menu.
- Settings > General controls transcript retention and provides Clear History. Modified video is treated as a different file and is transcribed again.
