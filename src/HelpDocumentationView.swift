import SwiftUI

struct HelpDocumentationView: View {
    fileprivate struct HelpSection: Identifiable {
        let id = UUID()
        let title: String
        let paragraphs: [String]
        let bullets: [String]
        let steps: [String]
        let note: String?

        init(
            title: String,
            paragraphs: [String] = [],
            bullets: [String] = [],
            steps: [String] = [],
            note: String? = nil
        ) {
            self.title = title
            self.paragraphs = paragraphs
            self.bullets = bullets
            self.steps = steps
            self.note = note
        }
    }

    fileprivate struct HelpTopic: Identifiable {
        let id: String
        let title: String
        let summary: String
        let symbolName: String
        let sections: [HelpSection]
        let shortcutGroups: [AppShortcutGroupDefinition]

        init(
            id: String,
            title: String,
            summary: String,
            symbolName: String,
            sections: [HelpSection],
            shortcutGroups: [AppShortcutGroupDefinition] = []
        ) {
            self.id = id
            self.title = title
            self.summary = summary
            self.symbolName = symbolName
            self.sections = sections
            self.shortcutGroups = shortcutGroups
        }
    }

    @State private var selection: HelpTopic.ID? = "welcome"

    private let topics: [HelpTopic] = [
        HelpTopic(
            id: "welcome",
            title: "Welcome to In/Out",
            summary: "Review media, find the moments you need, and export finished clips without leaving the timeline.",
            symbolName: "sparkles.rectangle.stack",
            sections: [
                HelpSection(
                    title: "The four tools",
                    bullets: [
                        "Clip is the main workspace for playback, trimming, transcripts, markers, AI Suggestions, and clip export.",
                        "Analyze checks the source for black frames, possible bad edits, silent gaps, and profanity.",
                        "Convert exports the complete source as video or audio without requiring an In/Out selection.",
                        "Inspect shows file, stream, color, bitrate, and audio/video timing information."
                    ]
                ),
                HelpSection(
                    title: "System requirements",
                    bullets: [
                        "macOS 14 Sonoma or later.",
                        "A Mac with Apple silicon."
                    ],
                    note: "Apple Intelligence requires a supported Mac, macOS 26 or later, and Apple Intelligence enabled in System Settings. Cloud AI providers require their own API keys."
                )
            ]
        ),
        HelpTopic(
            id: "open-download",
            title: "Open or download media",
            summary: "Open a local file or download supported media directly from a URL.",
            symbolName: "link.badge.plus",
            sections: [
                HelpSection(
                    title: "Open a file",
                    steps: [
                        "Choose File > Choose Media, drag a media file into the window, or open a file with In/Out from Finder.",
                        "Begin working as soon as the player and timeline appear. The waveform and thumbnails can continue loading in the background."
                    ]
                ),
                HelpSection(
                    title: "Download from a URL",
                    steps: [
                        "Choose File > Download Media from URL, or paste a URL into the opening screen.",
                        "Open More Options if you want to change quality, save location, or authentication.",
                        "Choose Download. In/Out opens the result when the download finishes."
                    ],
                    note: "Best Compatible is recommended for immediate playback. Best Available may take longer because incompatible media is converted to MP4."
                ),
                HelpSection(
                    title: "Browser cookies and multiple videos",
                    bullets: [
                        "Choose Use Browser Cookies when a site requires your existing signed-in browser session, then select the browser to use.",
                        "If a URL produces several media files, In/Out lets you choose one result or open all of them in separate windows.",
                        "The first URL download may install managed helper tools. In/Out maintains these tools separately from command-line copies on your Mac."
                    ]
                )
            ]
        ),
        HelpTopic(
            id: "clip",
            title: "Trim and navigate",
            summary: "Set an accurate range, move quickly through the source, and keep useful moments marked.",
            symbolName: "timeline.selection",
            sections: [
                HelpSection(
                    title: "Choose a clip",
                    steps: [
                        "Move the playhead to the beginning and press I to set the In point.",
                        "Move to the end and press O to set the Out point.",
                        "Drag either edge of the selection in the timeline for a visual adjustment."
                    ],
                    note: "Press X to clear the selection. Press Command-A to select the complete source."
                ),
                HelpSection(
                    title: "Playback and zoom",
                    bullets: [
                        "Press Space to play or pause. Use J, K, and L for shuttle playback.",
                        "Use Left and Right Arrow to step through the source.",
                        "Use Control-Space to play only the current In/Out selection.",
                        "Use the zoom controls or keyboard zoom shortcuts to inspect detail or fit the complete timeline.",
                        "Drag the divider below the player to resize it. Double-click the divider to toggle its preferred and maximum heights."
                    ]
                ),
                HelpSection(
                    title: "Markers and frame capture",
                    bullets: [
                        "Press M to add a marker at the playhead.",
                        "Use Up and Down Arrow to visit In/Out points, regular markers, AI suggestion markers, and the boundaries of suggested ranges.",
                        "Press Delete or Backspace to remove the selected regular marker.",
                        "Choose Capture Frame to save a PNG image of the frame at the playhead."
                    ]
                )
            ]
        ),
        HelpTopic(
            id: "transcript",
            title: "Work with transcripts",
            summary: "Generate, search, format, select, copy, and export time-aligned transcript text.",
            symbolName: "captions.bubble",
            sections: [
                HelpSection(
                    title: "Generate a transcript",
                    paragraphs: [
                        "Open the transcript sidebar in Clip, then choose Generate Transcript. In/Out uses Parakeet for fast, word-timed transcription. Starting AI Suggestions before a transcript exists can generate it automatically first."
                    ],
                    note: "Wording and timing can move slightly while transcription is still in progress."
                ),
                HelpSection(
                    title: "Reopen saved transcripts",
                    paragraphs: [
                        "Completed transcripts are stored locally without copying the original media. Opening the same unchanged file restores its transcript automatically."
                    ],
                    bullets: [
                        "Use Recent Transcripts on the opening screen or File > Open Recent Transcript to reopen media with saved transcript data.",
                        "Pin an entry to prevent automatic removal. Missing files can be located again from the entry’s contextual menu.",
                        "Settings > General controls transcript retention and provides Clear History. Modified media is treated as a different file and is transcribed again."
                    ]
                ),
                HelpSection(
                    title: "Read and navigate",
                    bullets: [
                        "Use View to switch between Compact Lines and Paragraphs, show or hide timecodes, and change text size.",
                        "Search for a word or phrase, then use the previous and next controls to move through matches.",
                        "Click a transcript row to move the playhead. Double-click a row to begin playback there.",
                        "During playback, the transcript follows the active row. Hiding the sidebar leaves the transcript available in the current window."
                    ]
                ),
                HelpSection(
                    title: "Select and copy text",
                    bullets: [
                        "Command-click rows to add or remove individual rows from the selection.",
                        "Shift-click to select a continuous range of rows.",
                        "Press Command-C to copy the selected rows. Right-click a selected row to copy the selection, or an unselected row to copy only that row.",
                        "Press Escape or click below the transcript rows to clear the selection.",
                        "Copied rows include timecodes only when timecodes are visible."
                    ]
                ),
                HelpSection(
                    title: "Export a transcript",
                    bullets: [
                        "Choose Export in the transcript sidebar to select Text, Markdown, CSV, JSON, SRT, or WebVTT.",
                        "Text and Markdown support Paragraphs, Compact Lines, or Continuous Text.",
                        "Readable exports can omit timecodes or include start times or start-and-end times. Continuous Text never includes timecodes."
                    ]
                )
            ]
        ),
        HelpTopic(
            id: "ai-suggestions",
            title: "Use AI Suggestions",
            summary: "Ask freeform questions or run reusable tasks that produce text, markers, or timeline ranges.",
            symbolName: "sparkles",
            sections: [
                HelpSection(
                    title: "Choose a provider",
                    paragraphs: [
                        "Open Settings > AI to choose Apple Intelligence, OpenAI, Claude, or Gemini. Cloud providers require an API key and send transcript text directly to that provider. API usage is separate from consumer chat subscriptions."
                    ]
                ),
                HelpSection(
                    title: "Freeform",
                    steps: [
                        "Choose AI Suggestions in Clip, then select Freeform.",
                        "Ask a question or describe the text you want, and choose Selected Clip or Entire Video.",
                        "Choose Ask AI. The response opens as a text result that you can copy or refine."
                    ]
                ),
                HelpSection(
                    title: "Preset Tasks",
                    paragraphs: [
                        "Preset Tasks includes Topic Changes, Highlights, Ad Breaks, Notable Excerpts, YouTube Chapters, and any custom tasks you create in Settings > AI. A task can return markers, ranges, a timestamped list, or a standalone document."
                    ],
                    bullets: [
                        "Only one request runs at a time, but completed results remain in separate closable tabs.",
                        "Use the refinement field below a result to ask questions or request changes. Text results retain browsable version history.",
                        "Settings > AI lets you hide built-in tasks and create reusable custom tasks with your own instructions and output type."
                    ]
                ),
                HelpSection(
                    title: "Use results with the timeline",
                    bullets: [
                        "Only the active result tab places its markers or ranges on the timeline.",
                        "Click a suggestion row to seek; double-click it to begin playback at that result.",
                        "Click a suggested range in the timeline to seek to its start. Double-click it to make the range the current In/Out selection.",
                        "Use Up and Down Arrow to navigate suggestion markers and both ends of suggested ranges.",
                        "Text documents do not add timeline decorations. Use Copy Text to place the finished text on the clipboard."
                    ]
                )
            ]
        ),
        HelpTopic(
            id: "analyze",
            title: "Analyze media",
            summary: "Run technical checks for visual, audio, timing, and transcript-based problems.",
            symbolName: "waveform.path.badge.magnifyingglass",
            sections: [
                HelpSection(
                    title: "Available checks",
                    bullets: [
                        "Detect black frames finds sustained sections where most of the image is black.",
                        "Detect possible bad edits checks for brief visual interruptions, suspiciously short shots, frozen video, abrupt audio discontinuities, clipped audio at edit points, timing gaps, decode problems, and mismatched stream endings.",
                        "Detect silent audio gaps finds silence longer than the duration shown beside the option.",
                        "Detect profanity uses the media transcript to locate potentially profane words."
                    ]
                ),
                HelpSection(
                    title: "Run and review",
                    steps: [
                        "Open Analyze and enable the checks you need.",
                        "Choose Run Analysis. Full video or audio scans can take time on long files.",
                        "Click a result to seek to it, or double-click to play it with context."
                    ],
                    note: "Results are review candidates, not definitive errors. Confirm each result in the player before making an editorial decision."
                )
            ]
        ),
        HelpTopic(
            id: "export",
            title: "Export and convert",
            summary: "Export a selected clip quickly, re-encode it with precise options, or convert the complete source.",
            symbolName: "square.and.arrow.up",
            sections: [
                HelpSection(
                    title: "Clip export modes",
                    bullets: [
                        "Fast uses stream passthrough with minimal processing and no re-encoding. Choose a compatible container and export quickly.",
                        "Advanced re-encodes the clip and provides container, video codec, resolution, bitrate, audio, caption, and processing options.",
                        "Audio Only exports the selected range as an audio file with format and audio-processing options."
                    ]
                ),
                HelpSection(
                    title: "Export or queue",
                    paragraphs: [
                        "Choose Export Clip to select a destination. Option-click Export Clip, or use Quick Export Clip, to use the configured automatic destination without a save dialog. If another job is running, the export button adds the clip to that window's queue."
                    ]
                ),
                HelpSection(
                    title: "Burned captions",
                    paragraphs: [
                        "Advanced video export can generate and burn captions into the exported image. Caption appearance can be selected in the export options or set as a default in Settings."
                    ]
                ),
                HelpSection(
                    title: "Convert the complete source",
                    paragraphs: [
                        "Use Convert when you need the complete file rather than the current In/Out selection. Video uses the same options as Advanced clip export; Audio Only uses the same options as Audio Only clip export."
                    ]
                )
            ]
        ),
        HelpTopic(
            id: "inspect",
            title: "Inspect media",
            summary: "Review technical details about the source without running a separate analysis.",
            symbolName: "info.circle",
            sections: [
                HelpSection(
                    title: "What Inspect shows",
                    bullets: [
                        "The technical summary lists the primary video, audio, and timing characteristics at a glance.",
                        "Video details include stream count, codec, resolution, frame rate, bitrate, color primaries, and transfer function.",
                        "Audio details include stream count, codec, sample rate, channel layout, and bitrate.",
                        "Container details include duration, overall bitrate, file size, and container type.",
                        "Timing compares the playable start, duration, and end of the first video and audio streams and calls out meaningful offsets."
                    ]
                ),
                HelpSection(
                    title: "File and console",
                    bullets: [
                        "Choose Show in Finder to locate the source, or right-click its icon to copy the path.",
                        "Open Console to review output from helper tools. You can copy or clear the console when troubleshooting."
                    ]
                )
            ]
        ),
        HelpTopic(
            id: "updates",
            title: "Install and update",
            summary: "Install In/Out once, then let the built-in updater install new releases in place.",
            symbolName: "arrow.down.app",
            sections: [
                HelpSection(
                    title: "Install In/Out",
                    steps: [
                        "Open the downloaded In-Out DMG file.",
                        "Drag In-Out.app onto the Applications folder shown in the installer window.",
                        "Open In/Out from Applications. You can eject the installer disk image afterward."
                    ]
                ),
                HelpSection(
                    title: "Install an update",
                    steps: [
                        "Choose In/Out > Check for Updates. In/Out also checks automatically when it opens.",
                        "When an update is available, choose Install Update.",
                        "In/Out downloads, installs, and relaunches the new version automatically."
                    ],
                    note: "Updating from a version installed before in-place updates were introduced may require one final DMG installation."
                )
            ]
        ),
        HelpTopic(
            id: "shortcuts",
            title: "Keyboard shortcuts",
            summary: "Use the keyboard for transport, trimming, markers, tool switching, and export.",
            symbolName: "command",
            sections: [
                HelpSection(
                    title: "Tip",
                    paragraphs: [
                        "You can use every primary workflow with the mouse. Learning Space, I, O, M, Up Arrow, Down Arrow, and the export shortcuts makes repeated clipping substantially faster."
                    ]
                )
            ],
            shortcutGroups: AppShortcutCatalog.helpGroups
        ),
        HelpTopic(
            id: "components",
            title: "Managed components",
            summary: "In/Out maintains the helper tools used for downloads, exports, analysis, and transcription.",
            symbolName: "shippingbox",
            sections: [
                HelpSection(
                    title: "Included and managed tools",
                    bullets: [
                        "ffmpeg and ffprobe handle export, conversion, media scanning, and inspection.",
                        "Managed Python, yt-dlp, and Deno handle supported URL downloads.",
                        "Parakeet provides fast, word-timed transcripts for the Clip sidebar and AI Suggestions.",
                        "whisper-cli and its model support profanity detection and generated burned captions."
                    ]
                ),
                HelpSection(
                    title: "Check or repair tools",
                    paragraphs: [
                        "Open Settings > Tools to check tool availability. Downloader controls can check for updates, repair the managed downloader, or roll back to the previous yt-dlp version. In/Out isolates app-managed downloads from personal yt-dlp and Python configuration."
                    ],
                    note: "When reporting a helper-tool problem, open Inspect > Console and include the relevant error text."
                )
            ]
        )
    ]

    private var selectedTopic: HelpTopic {
        topics.first(where: { $0.id == selection }) ?? topics[0]
    }

    var body: some View {
        NavigationSplitView {
            List(topics, selection: $selection) { topic in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.title)
                            .font(.body.weight(.medium))
                        Text(topic.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } icon: {
                    Image(systemName: topic.symbolName)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .tag(topic.id)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 260)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(selectedTopic.title, systemImage: selectedTopic.symbolName)
                            .font(.largeTitle.weight(.semibold))
                        Text(selectedTopic.summary)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(selectedTopic.sections) { section in
                        HelpArticleSectionView(section: section)
                    }

                    if !selectedTopic.shortcutGroups.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(selectedTopic.shortcutGroups) { group in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(group.title)
                                        .font(.headline)

                                    VStack(spacing: 8) {
                                        ForEach(group.items) { item in
                                            shortcutRow(item)
                                        }
                                    }
                                }
                                .padding(18)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(helpCardBackground)
                            }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 620)
    }

    private var helpCardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private func shortcutRow(_ item: AppShortcutDefinition) -> some View {
        HStack(spacing: 16) {
            Text(item.action)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(item.keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                }
            }
            .fixedSize()
        }
    }
}

private struct HelpArticleSectionView: View {
    let section: HelpDocumentationView.HelpSection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.title)
                .font(.title3.weight(.semibold))

            ForEach(section.paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !section.steps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1).")
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .trailing)
                            Text(step)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !section.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(section.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(.secondary)
                                .padding(.top, 7)
                            Text(bullet)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let note = section.note {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.secondary)
                    Text(note)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }
}
