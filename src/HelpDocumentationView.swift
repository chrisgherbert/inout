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
            summary: "In/Out helps you review media, trim clips, inspect content, and export finished results with as little friction as possible.",
            symbolName: "sparkles.rectangle.stack",
            sections: [
                HelpSection(
                    title: "What you can do",
                    paragraphs: [
                        "Use the Clip tab to set In and Out points, review the timeline, and export a selection. Use Analyze to detect black frames, silence gaps, and profanity. Use Convert to export audio from the full source. Use Inspect to review file details and work with transcripts."
                    ],
                    bullets: [
                        "Open a file from Finder, choose File > Open, or drag media into the app.",
                        "Download supported media directly from a URL.",
                        "Generate transcripts and use them to navigate spoken moments.",
                        "Export video clips, audio-only files, or queued jobs."
                    ]
                ),
                HelpSection(
                    title: "System requirements",
                    bullets: [
                        "macOS 13 Ventura or later.",
                        "Apple silicon for the current app build."
                    ],
                    note: "Some features, including URL downloads and transcription, depend on bundled helper tools. If those components are unavailable, the related features are hidden or disabled."
                )
            ]
        ),
        HelpTopic(
            id: "get-started",
            title: "Get started",
            summary: "Open a source file, review it in the timeline, then mark the part you want to keep.",
            symbolName: "play.square",
            sections: [
                HelpSection(
                    title: "Open media",
                    steps: [
                        "Choose File > Open, or drag a file into the window.",
                        "If you want to download media from a supported site, choose File > Download Media from URL.",
                        "Wait for the player, timeline, waveform, and thumbnails to appear. You can begin working before every visual element finishes loading."
                    ]
                ),
                HelpSection(
                    title: "Choose a range",
                    steps: [
                        "Move the playhead to the point where the clip should begin, then press I.",
                        "Move to the point where the clip should end, then press O.",
                        "Adjust the selection directly in the timeline by dragging the clip edges."
                    ],
                    note: "Press X to clear the current selection. Press Command-A to select the full source."
                )
            ]
        ),
        HelpTopic(
            id: "clip",
            title: "Trim and navigate",
            summary: "The Clip tab is designed for fast review, accurate trimming, and quick exports.",
            symbolName: "timeline.selection",
            sections: [
                HelpSection(
                    title: "Move through the timeline",
                    bullets: [
                        "Use Space to play or pause.",
                        "Use J, K, and L for shuttle playback.",
                        "Use the arrow keys to step and navigate markers.",
                        "Use the timeline zoom controls or the keyboard zoom shortcuts to focus on details or fit the full source."
                    ]
                ),
                HelpSection(
                    title: "Work with markers",
                    paragraphs: [
                        "Markers help you keep track of important moments in the source. In/Out includes the clip In and Out points when you navigate with the marker keys, so you can move through edit boundaries and saved markers in one pass."
                    ],
                    bullets: [
                        "Press M to add a marker at the playhead.",
                        "Press the Up or Down Arrow key to move to the previous or next marker.",
                        "Press Delete or Backspace to remove the selected marker."
                    ]
                ),
                HelpSection(
                    title: "Play only the selected range",
                    paragraphs: [
                        "Use Control-Space to play the current selection only. Playback stops at the Out point. Use the same shortcut again to pause."
                    ]
                )
            ]
        ),
        HelpTopic(
            id: "transcript",
            title: "Work with transcripts",
            summary: "Generate a transcript to search spoken content, follow playback, and jump directly to key moments.",
            symbolName: "captions.bubble",
            sections: [
                HelpSection(
                    title: "Generate a transcript",
                    paragraphs: [
                        "You can generate a transcript from the Clip tab or from Inspect. In/Out uses the bundled Whisper model to create transcript segments and keep them aligned to time."
                    ],
                    bullets: [
                        "Open the transcript sidebar from the Clip tab, then choose Generate Transcript.",
                        "Or switch to Inspect and generate the transcript there.",
                        "When a transcript is ready, you can export it as plain text or SRT."
                    ]
                ),
                HelpSection(
                    title: "Search and follow",
                    bullets: [
                        "Search within the transcript to find words or phrases.",
                        "Select a row to jump the playhead to that point in the source.",
                        "During playback, the transcript can follow the active row automatically."
                    ],
                    note: "The transcript sidebar can be hidden without removing the transcript from the project."
                ),
                HelpSection(
                    title: "Use transcripts in exports",
                    paragraphs: [
                        "In Advanced clip export mode, you can automatically generate and burn captions into the exported video. Choose a caption style in the export panel or in Preferences."
                    ]
                )
            ]
        ),
        HelpTopic(
            id: "analyze",
            title: "Analyze media",
            summary: "Analyze helps you find black frames, silence gaps, profanity, and transcript-backed moments worth reviewing.",
            symbolName: "waveform.path.badge.magnifyingglass",
            sections: [
                HelpSection(
                    title: "Run analysis",
                    steps: [
                        "Open the Analyze tab.",
                        "Choose the checks you want to run.",
                        "Start analysis and review the results as they appear."
                    ]
                ),
                HelpSection(
                    title: "Review results",
                    bullets: [
                        "Double-click a row to jump to that time in the source.",
                        "Use the detected ranges as review points before you export.",
                        "Profanity detection can reuse a generated transcript to speed up future runs."
                    ]
                )
            ]
        ),
        HelpTopic(
            id: "export",
            title: "Export and convert",
            summary: "Choose the export mode that matches the result you need: quick compatibility, deeper control, or audio only.",
            symbolName: "square.and.arrow.up",
            sections: [
                HelpSection(
                    title: "Clip export modes",
                    bullets: [
                        "Fast keeps processing to a minimum for quick exports.",
                        "Advanced adds control over codec, container, bitrate, resolution, and captions.",
                        "Audio Only exports just the audio from the selected range."
                    ]
                ),
                HelpSection(
                    title: "Queue or export now",
                    paragraphs: [
                        "You can export the current clip immediately or add it to the queue. The queue is useful when you want to prepare several clips first and export them later."
                    ]
                ),
                HelpSection(
                    title: "Convert full-file audio",
                    paragraphs: [
                        "Use the Convert tab to export audio from the full source as MP3 or M4A. This is separate from clip export and does not require an In/Out selection."
                    ]
                )
            ]
        ),
        HelpTopic(
            id: "shortcuts",
            title: "Keyboard shortcuts",
            summary: "Most editing tasks can be done quickly from the keyboard.",
            symbolName: "command",
            sections: [
                HelpSection(
                    title: "Tip",
                    paragraphs: [
                        "You can keep using the mouse, but learning a few transport and trim shortcuts makes the app feel much faster right away."
                    ]
                )
            ],
            shortcutGroups: AppShortcutCatalog.helpGroups
        ),
        HelpTopic(
            id: "components",
            title: "Bundled components",
            summary: "In/Out includes the command-line tools it needs for exports, downloads, and transcription.",
            symbolName: "shippingbox",
            sections: [
                HelpSection(
                    title: "Included tools",
                    bullets: [
                        "ffmpeg and ffprobe for export, conversion, and media inspection.",
                        "yt-dlp for supported URL downloads.",
                        "A managed Python runtime for URL download setup.",
                        "whisper-cli and a bundled model for transcripts, captions, and transcript-backed analysis."
                    ],
                    note: "If one of these components is missing or unavailable, the related feature is hidden or disabled rather than failing unexpectedly."
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
