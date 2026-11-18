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

After transcription finishes, click **Clean Up** beside View and Export to open its popover. Choose a provider, check the configured model, and optionally add names and episode context. Click **Start Cleanup** to run in the background. The popover stays open and updates to show progress and results; click outside it to dismiss. Provider selection is remembered; context is retained for the current source.

Hold Option to change the button to **Quick Clean Up**. Clicking starts immediately using the saved settings and automatically applies all verified corrections when finished. You can release Option after clicking. A secondary **Quick Clean Up** button in the setup popover offers the same automatic acceptance using the provider and context shown there. Quick mode is available when no request is running and no corrections await review. Pending corrections continue to open their results popover, even while Option is held.

The bottom activity area shows progress and Cancel Cleanup, alongside other work. Opening the cleanup popover while running shows a brief progress summary and cancellation; dismissing it leaves the task running. A single full-transcript request shows indeterminate progress until the model responds.

When results are ready, the toolbar button reads **Review N Corrections**. Its popover offers **Review Corrections**, which opens the sidebar’s Corrections tab, or **Apply All**, which applies every suggestion. These actions keep the popover open; applying corrections changes it to the after-run options. Discard Results clears pending suggestions. In the Corrections tab, each suggestion shows original and corrected wording, its timestamp, and Play Passage. Check the changes you want and apply them; Review Later keeps your selections.

After application, confirmation and **Undo** appear below the transcript. Opening **Clean Up** again shows the applied count, **Undo Cleanup**, **Run Again…** to return to setup, and **Restore Original Transcript** below a divider. Changing or regenerating the source clears outdated cleanup work.

Cloud cleanup sends the full transcript in one request when it fits the request budget, so the model can use context from throughout the recording. Oversized transcripts are split into larger sections processed up to three at a time. OpenAI receives readable transcript paragraphs and returns compact phrase corrections; the app resolves the timing anchors locally. Cleanup disables extra reasoning on supported OpenAI models. If a response is incomplete or malformed, the app retries two smaller correction ranges once while retaining transcript context. Suggestions that cannot be matched exactly are skipped and counted in the Corrections tab. Request timings, token usage, and retries appear in the Activity Console. Apple Intelligence uses small sections processed locally.

In the Corrections tab, you can play a passage, select individual changes, and apply the selected corrections. Cleanup prioritizes names, places, organizations, and other proper nouns and also proposes clear speech-recognition fixes. It preserves the speaker's wording, grammar, repetitions, and fillers. A local spelling-similarity check rejects substantially different replacements before review, helping prevent substitutions of a different person, organization, or title. This check is a safeguard rather than a guarantee; review proposals before applying them. Optional context can help identify intended spellings.

Corrections keep the original word or phrase time spans. Caption line breaks and grouping may change to fit corrected text. Both readable transcripts and exported captions use the corrections.

The original transcript is saved with the corrected version. Open the cleanup popover and choose Restore Original Transcript to revert, including after reopening the video. Apple Intelligence runs locally; cloud providers receive transcript text and the optional context using your API key.

## Reopen saved transcripts

Completed transcripts are stored locally without copying the original video. Opening the same unchanged file restores its transcript automatically.

- Use Recent Transcripts on the opening screen or File > Open Recent Transcript to reopen a video with saved transcript data.
- Pin an entry to prevent automatic removal. Missing files can be located again from the entry's contextual menu.
- Settings > General controls transcript retention and provides Clear History. Modified video is treated as a different file and is transcribed again.
