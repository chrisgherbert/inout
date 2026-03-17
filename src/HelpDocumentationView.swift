import SwiftUI

struct HelpDocumentationView: View {
    private struct HelpSection: Identifiable {
        let id = UUID()
        let title: String
        let items: [String]
    }

    private struct ShortcutItem: Identifiable {
        let id = UUID()
        let action: String
        let keys: [String]
    }

    private let sections: [HelpSection] = [
        HelpSection(
            title: "System Requirements",
            items: [
                "In/Out requires macOS 13 Ventura or later.",
                "Apple Silicon is required for the current app build."
            ]
        ),
        HelpSection(
            title: "Getting Started",
            items: [
                "Choose a media file with Choose Media, or drag a file into the main window.",
                "You can also import media from a URL via File > Download Media from URL…",
                "Use the top tool tabs to switch between Clip, Analyze, Convert, and Inspect.",
                "The footer always shows current activity, progress, and completion state."
            ]
        ),
        HelpSection(
            title: "Clip Tab",
            items: [
                "Create new clips by setting In/Out points on the timeline.",
                "Set points with drag handles, direct timecode entry, keyboard shortcuts, or playhead actions.",
                "Add timeline markers with M, then use Up/Down arrows to jump to previous/next marker (In/Out points are included).",
                "If a transcript is available, you can use the transcript sidebar to search, follow playback, and jump directly to spoken moments.",
                "Choose Fast, Advanced, or Audio Only export modes depending on speed and compatibility needs.",
                "In Advanced mode, enable Auto-generate and burn captions (Whisper) to add hardcoded subtitles.",
                "When caption burn-in is enabled, a per-export caption style picker appears next to the toggle.",
                "Set the default caption style in Preferences > Clip > Burned-In Captions."
            ]
        ),
        HelpSection(
            title: "Analyze Tab",
            items: [
                "Run black-frame detection, silence-gap detection, and profanity detection.",
                "Watch results populate while processing, including timeline markers and segment lists.",
                "Double-click detected rows to jump playback to those timestamps."
            ]
        ),
        HelpSection(
            title: "Convert Tab",
            items: [
                "Export full-file audio using MP3 or M4A formats.",
                "Set bitrate and export destination from one panel.",
                "Use this tab for audio extraction without creating a timeline clip."
            ]
        ),
        HelpSection(
            title: "Inspect Tab",
            items: [
                "Review source metadata such as duration, bitrate, codec, frame rate, and resolution.",
                "Generate, search, and export transcripts from the Inspect workflow.",
                "Use Show in Finder to jump to the current source file.",
                "Use this tab as a quick technical snapshot before export or analysis."
            ]
        ),
        HelpSection(
            title: "Keyboard Shortcuts",
            items: []
        ),
        HelpSection(
            title: "Bundled Components",
            items: [
                "ffmpeg and ffprobe are bundled for export, conversion, and media inspection workflows.",
                "yt-dlp is bundled for URL import/download workflows.",
                "A managed Python runtime is installed automatically when URL download support is set up.",
                "whisper-cli plus a bundled model are used for transcripts, profanity detection, and caption generation.",
                "If bundled transcription resources are missing, transcript and caption features will be unavailable."
            ]
        )
    ]

    private let shortcutItems: [ShortcutItem] = [
        ShortcutItem(action: "Play/Pause", keys: ["Space"]),
        ShortcutItem(action: "Pause transport", keys: ["K"]),
        ShortcutItem(action: "Shuttle forward (repeat to speed up)", keys: ["L"]),
        ShortcutItem(action: "Shuttle backward (repeat to speed up)", keys: ["J"]),
        ShortcutItem(action: "Jump to timeline start", keys: ["Home"]),
        ShortcutItem(action: "Jump to timeline end", keys: ["End"]),
        ShortcutItem(action: "Set clip start at playhead", keys: ["I"]),
        ShortcutItem(action: "Set clip end at playhead", keys: ["O"]),
        ShortcutItem(action: "Clear clip in/out", keys: ["X"]),
        ShortcutItem(action: "Add marker at playhead", keys: ["M"]),
        ShortcutItem(action: "Delete selected marker", keys: ["Delete"]),
        ShortcutItem(action: "Delete selected marker", keys: ["Backspace"]),
        ShortcutItem(action: "Previous marker (includes In/Out points)", keys: ["↑"]),
        ShortcutItem(action: "Next marker (includes In/Out points)", keys: ["↓"]),
        ShortcutItem(action: "Step backward 10 frames", keys: ["⇧", "←"]),
        ShortcutItem(action: "Step forward 10 frames", keys: ["⇧", "→"]),
        ShortcutItem(action: "Capture frame", keys: ["⌘", "⌥", "S"]),
        ShortcutItem(action: "Export clip", keys: ["⌘", "E"]),
        ShortcutItem(action: "Quick export clip (no save dialog)", keys: ["⌘", "⇧", "E"]),
        ShortcutItem(action: "Export audio", keys: ["⌘", "⌥", "E"]),
        ShortcutItem(action: "Choose media", keys: ["⌘", "O"]),
        ShortcutItem(action: "Zoom timeline in", keys: ["⌘", "+"]),
        ShortcutItem(action: "Zoom timeline out", keys: ["⌘", "-"]),
        ShortcutItem(action: "Reset timeline zoom", keys: ["⌘", "0"]),
        ShortcutItem(action: "Switch to Clip tool", keys: ["⌘", "1"]),
        ShortcutItem(action: "Switch to Analyze tool", keys: ["⌘", "2"]),
        ShortcutItem(action: "Switch to Convert tool", keys: ["⌘", "3"]),
        ShortcutItem(action: "Switch to Inspect tool", keys: ["⌘", "4"]),
        ShortcutItem(action: "Run analysis", keys: ["⌘", "R"]),
        ShortcutItem(action: "Stop active analysis/export", keys: ["⌘", "."]),
        ShortcutItem(action: "Open help", keys: ["⌘", "⇧", "/"])
    ]

    @ViewBuilder
    private func shortcutRow(_ item: ShortcutItem) -> some View {
        HStack(spacing: 10) {
            Text(item.action)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                ForEach(item.keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.12))
                        )
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 1)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("In/Out Help")
                    .font(.title2.weight(.semibold))

                Text("Quick guide to core workflows and shortcuts.")
                    .foregroundStyle(.secondary)

                ForEach(sections) { section in
                    GroupBox(section.title) {
                        if section.title == "Keyboard Shortcuts" {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(shortcutItems) { item in
                                    shortcutRow(item)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(section.items, id: \.self) { item in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("•")
                                        Text(item)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}
