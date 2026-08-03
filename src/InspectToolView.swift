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

    private var videoSummary: String {
        guard let sourceInfo, sourceInfo.videoStreamCount > 0 else { return "No video stream" }
        return [
            sourceInfo.videoCodec,
            sourceInfo.resolution,
            sourceInfo.frameRate.map { String(format: "%.2f fps", $0) }
        ]
        .compactMap { $0 }
        .joined(separator: "  •  ")
    }

    private var audioSummary: String {
        guard let sourceInfo, sourceInfo.audioStreamCount > 0 else { return "No audio stream" }
        return [
            sourceInfo.audioCodec,
            channelDescription(sourceInfo.channels),
            sourceInfo.sampleRateHz.map(formatSampleRate)
        ]
        .compactMap { $0 }
        .joined(separator: "  •  ")
    }

    private var timingOffsetSeconds: Double? {
        guard let sourceInfo,
              let videoStart = sourceInfo.videoStartSeconds,
              let videoDuration = sourceInfo.videoDurationSeconds,
              let audioStart = sourceInfo.audioStartSeconds,
              let audioDuration = sourceInfo.audioDurationSeconds else {
            return nil
        }
        let startOffset = abs(audioStart - videoStart)
        let endOffset = abs((audioStart + audioDuration) - (videoStart + videoDuration))
        return max(startOffset, endOffset)
    }

    private var timingSummary: String {
        guard let offset = timingOffsetSeconds else {
            return "A/V comparison unavailable"
        }
        if offset < 0.1 {
            return "Audio and video timing aligned"
        }
        return "A/V offset detected (up to \(formatPreciseDuration(offset)))"
    }

    private var timingAccent: Color {
        guard let offset = timingOffsetSeconds else { return .secondary }
        return offset < 0.1 ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)
    }

    private func channelDescription(_ channels: Int?) -> String? {
        guard let channels else { return nil }
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1 channels"
        case 8: return "7.1 channels"
        default: return "\(channels) channels"
        }
    }

    private func formatSampleRate(_ hertz: Double) -> String {
        if hertz >= 1000 {
            return String(format: "%.1f kHz", hertz / 1000)
                .replacingOccurrences(of: ".0 kHz", with: " kHz")
        }
        return String(format: "%.0f Hz", hertz)
    }

    private func formatPreciseDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        return String(format: "%.3f s", seconds)
    }

    private func streamEnd(start: Double?, duration: Double?) -> Double? {
        guard let start, let duration else { return nil }
        return start + duration
    }

    @ViewBuilder
    private func summaryRow(label: String, value: String, icon: String, accent: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(accent)
                .frame(width: 16)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func streamCountDescription(_ count: Int) -> String {
        "\(count) \(count == 1 ? "stream" : "streams")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sourceURL {
                GroupBox("Technical Summary") {
                    VStack(alignment: .leading, spacing: 8) {
                        summaryRow(label: "Video", value: videoSummary, icon: "film")
                        summaryRow(label: "Audio", value: audioSummary, icon: "waveform")
                        summaryRow(label: "Timing", value: timingSummary, icon: "clock", accent: timingAccent)
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
                        Text("Streams: \(streamCountDescription(sourceInfo?.videoStreamCount ?? 0))")
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
                        Text("Streams: \(streamCountDescription(sourceInfo?.audioStreamCount ?? 0))")
                        Text("Audio codec: \(sourceInfo?.audioCodec ?? "—")")
                        Text("Sample rate: \(sourceInfo?.sampleRateHz.map { String(format: "%.0f Hz", $0) } ?? "—")")
                        Text("Channels: \(channelDescription(sourceInfo?.channels) ?? "—")")
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

                GroupBox("Timing") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Container duration: \(sourceInfo?.durationSeconds.map(formatSeconds) ?? "—")")
                        Divider()
                        Text("Video start: \(formatPreciseDuration(sourceInfo?.videoStartSeconds))")
                        Text("Video duration: \(sourceInfo?.videoDurationSeconds.map(formatSeconds) ?? "—")")
                        Text("Video end: \(streamEnd(start: sourceInfo?.videoStartSeconds, duration: sourceInfo?.videoDurationSeconds).map(formatSeconds) ?? "—")")
                        Divider()
                        Text("Audio start: \(formatPreciseDuration(sourceInfo?.audioStartSeconds))")
                        Text("Audio duration: \(sourceInfo?.audioDurationSeconds.map(formatSeconds) ?? "—")")
                        Text("Audio end: \(streamEnd(start: sourceInfo?.audioStartSeconds, duration: sourceInfo?.audioDurationSeconds).map(formatSeconds) ?? "—")")
                        Label(timingSummary, systemImage: timingOffsetSeconds.map { $0 < 0.1 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill" } ?? "questionmark.circle")
                            .foregroundStyle(timingAccent)
                            .padding(.top, 2)
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
