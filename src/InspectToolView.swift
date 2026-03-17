import SwiftUI
import AppKit
import AVKit

struct InspectToolView: View {
    @ObservedObject var activity: ActivityPresentationModel
    let sourceURL: URL?
    let analysis: FileAnalysis?
    let sourceInfo: SourceMediaInfo?
    let transcriptSegments: [TranscriptSegment]
    let transcriptStatusText: String
    let canGenerateTranscript: Bool
    let isGeneratingTranscript: Bool
    let whisperTranscriptionAvailable: Bool
    let hasAudioTrack: Bool
    let generateTranscript: () -> Void
    let exportTranscript: () -> Void
    let toggleActivityConsole: () -> Void
    let copyActivityConsole: () -> Void
    let clearActivityConsole: () -> Void
    let isCompactLayout: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var transcriptSearchText = ""
    @State private var transcriptFontSize: CGFloat = 14
    private var allTranscriptRows: [TranscriptDisplayRow] {
        transcriptSegments.map { segment in
            TranscriptDisplayRow(
                id: segment.id,
                start: segment.start,
                startLabel: formatSeconds(segment.start),
                text: segment.text,
                normalizedText: normalizedTranscriptSearchText(segment.text)
            )
        }
    }

    private var filteredTranscriptRows: [TranscriptDisplayRow] {
        let query = normalizedTranscriptSearchText(transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else {
            return allTranscriptRows
        }
        return allTranscriptRows.filter { $0.normalizedText.contains(query) }
    }

    private func fileIcon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sourceURL {
                GroupBox("File") {
                    HStack(alignment: .top, spacing: 12) {
                        Image(nsImage: fileIcon(for: sourceURL))
                            .interpolation(.high)
                            .frame(width: 64, height: 64, alignment: .topLeading)
                            .onDrag {
                                NSItemProvider(contentsOf: sourceURL) ?? NSItemProvider()
                            }
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                                }
                                Button("Copy Path") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(sourceURL.path, forType: .string)
                                }
                            }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(sourceURL.lastPathComponent)
                                    .font(.headline)
                                Spacer()
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Text(sourceURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        adaptiveContainerFill(
                            material: .thinMaterial,
                            fallback: Color(nsColor: .controlBackgroundColor),
                            reduceTransparency: reduceTransparency
                        ),
                        in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    )
                }

                GroupBox("Video") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Codec: \(sourceInfo?.videoCodec ?? "—")")
                        Text("Resolution: \(sourceInfo?.resolution ?? "—")")
                        Text("Frame rate: \(sourceInfo?.frameRate.map { String(format: "%.2f fps", $0) } ?? "—")")
                        Text("Video bitrate: \(formatBitrate(sourceInfo?.videoBitrateBps))")
                        Text("Color primaries: \(sourceInfo?.colorPrimaries ?? "—")")
                        Text("Transfer function: \(sourceInfo?.colorTransfer ?? "—")")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        adaptiveContainerFill(
                            material: .thinMaterial,
                            fallback: Color(nsColor: .controlBackgroundColor),
                            reduceTransparency: reduceTransparency
                        ),
                        in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    )
                }

                GroupBox("Audio") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Audio codec: \(sourceInfo?.audioCodec ?? "—")")
                        Text("Sample rate: \(sourceInfo?.sampleRateHz.map { String(format: "%.0f Hz", $0) } ?? "—")")
                        Text("Channels: \(sourceInfo?.channels.map(String.init) ?? "—")")
                        Text("Audio bitrate: \(formatBitrate(sourceInfo?.audioBitrateBps))")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        adaptiveContainerFill(
                            material: .thinMaterial,
                            fallback: Color(nsColor: .controlBackgroundColor),
                            reduceTransparency: reduceTransparency
                        ),
                        in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    )
                }

                GroupBox("Container") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Duration: \(sourceInfo?.durationSeconds.map(formatSeconds) ?? "—")")
                        Text("Overall bitrate: \(formatBitrate(sourceInfo?.overallBitrateBps))")
                        Text("File size: \(formatFileSize(sourceInfo?.fileSizeBytes))")
                        Text("Container: \(sourceInfo?.containerDescription ?? "—")")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(
                        adaptiveContainerFill(
                            material: .thinMaterial,
                            fallback: Color(nsColor: .controlBackgroundColor),
                            reduceTransparency: reduceTransparency
                        ),
                        in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    )
                }

                GroupBox("Transcript") {
                    VStack(alignment: .leading, spacing: 8) {
                        if transcriptSegments.isEmpty {
                            Text(transcriptStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if !whisperTranscriptionAvailable {
                                Text("Whisper binary/model is not available in this app bundle.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if !hasAudioTrack {
                                Text("No audio track available.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Button(isGeneratingTranscript ? "Generating Transcript…" : "Generate Transcript") {
                                generateTranscript()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!canGenerateTranscript || isGeneratingTranscript)
                        } else {
                            HStack(spacing: 8) {
                                TextField("Search transcript", text: $transcriptSearchText)
                                    .textFieldStyle(.roundedBorder)

                                HStack(spacing: 4) {
                                    Button {
                                        transcriptFontSize = max(11, transcriptFontSize - 1)
                                    } label: {
                                        Image(systemName: "textformat.size.smaller")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button {
                                        transcriptFontSize = min(24, transcriptFontSize + 1)
                                    } label: {
                                        Image(systemName: "textformat.size.larger")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }

                                Button("Export…") {
                                    exportTranscript()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Text(transcriptStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TranscriptTableView(
                                rows: filteredTranscriptRows,
                                rowsVersion: filteredTranscriptRows.count ^ Int(transcriptFontSize * 100),
                                fontSize: transcriptFontSize
                            )
                            .frame(minHeight: 120, maxHeight: 220)

                            Text("Tip: Use Shift/Cmd-click to select multiple rows, then press Cmd-C to copy.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        adaptiveContainerFill(
                            material: .thinMaterial,
                            fallback: Color(nsColor: .controlBackgroundColor),
                            reduceTransparency: reduceTransparency
                        ),
                        in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    )
                }

                GroupBox("Console") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Button(activity.showActivityConsole ? "Hide Console" : "Show Console") {
                                toggleActivityConsole()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Copy") {
                                copyActivityConsole()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(activity.activityConsoleText.isEmpty)

                            Button("Clear") {
                                clearActivityConsole()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(activity.activityConsoleText.isEmpty)
                            Spacer(minLength: 0)
                        }

                        if activity.showActivityConsole {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(activity.activityConsoleText.isEmpty ? "Console output will appear here while tools run." : activity.activityConsoleText)
                                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Color.clear
                                            .frame(height: 1)
                                            .id("inspect-console-end")
                                    }
                                }
                                .frame(minHeight: 110, maxHeight: 180)
                                .onChange(of: activity.activityConsoleText) { _ in
                                    proxy.scrollTo("inspect-console-end", anchor: .bottom)
                                }
                                .onAppear {
                                    proxy.scrollTo("inspect-console-end", anchor: .bottom)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        adaptiveContainerFill(
                            material: .thinMaterial,
                            fallback: Color(nsColor: .controlBackgroundColor),
                            reduceTransparency: reduceTransparency
                        ),
                        in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    )
                }
            } else {
                EmptyToolView(title: "Inspect", subtitle: "Choose source media to inspect metadata and results.")
            }

            if !isCompactLayout {
                Spacer()
            }
        }
    }
}
