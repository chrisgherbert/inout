import SwiftUI
import AppKit

struct InspectToolView: View {
    @ObservedObject var activity: ActivityPresentationModel
    let sourceURL: URL?
    let sourceInfo: SourceMediaInfo?
    let toggleActivityConsole: () -> Void
    let copyActivityConsole: () -> Void
    let clearActivityConsole: () -> Void
    let isCompactLayout: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
