import SwiftUI
import AppKit
import AVKit

struct InspectToolView: View {
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
    let showActivityConsole: Bool
    let activityConsoleText: String
    let toggleActivityConsole: () -> Void
    let copyActivityConsole: () -> Void
    let clearActivityConsole: () -> Void
    let isCompactLayout: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var transcriptSearchText = ""
    @State private var transcriptFontSize: CGFloat = 14

    private var filteredTranscriptSegments: [TranscriptSegment] {
        let query = transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return transcriptSegments }
        return transcriptSegments.filter { $0.text.localizedCaseInsensitiveContains(query) }
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

                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(filteredTranscriptSegments) { segment in
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(formatSeconds(segment.start))
                                                .font(.system(size: max(11, transcriptFontSize - 1), weight: .regular, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
                                                .frame(width: 112, alignment: .leading)
                                            Text(segment.text)
                                                .font(.system(size: transcriptFontSize))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .textSelection(.enabled)
                            }
                            .frame(minHeight: 120, maxHeight: 220)
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
                            Button(showActivityConsole ? "Hide Console" : "Show Console") {
                                toggleActivityConsole()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Copy") {
                                copyActivityConsole()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(activityConsoleText.isEmpty)

                            Button("Clear") {
                                clearActivityConsole()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(activityConsoleText.isEmpty)
                            Spacer(minLength: 0)
                        }

                        if showActivityConsole {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(activityConsoleText.isEmpty ? "Console output will appear here while tools run." : activityConsoleText)
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
                                .onChange(of: activityConsoleText) { _ in
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

struct StatusFooterStripView: View {
    @ObservedObject var model: WorkspaceViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var stateColor: Color {
        switch model.lastActivityState {
        case .idle:
            return .secondary
        case .running:
            return .accentColor
        case .success:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }

    private var footerStateLabel: String {
        guard model.lastActivityState == .running else {
            return model.lastResultLabel
        }

        let orderedJobs = model.queuedJobs.sorted(by: { $0.createdAt < $1.createdAt })
        guard !orderedJobs.isEmpty else { return model.lastResultLabel }

        if let runningIndex = orderedJobs.firstIndex(where: { $0.status == .running }) {
            return "Running (\(runningIndex + 1)/\(orderedJobs.count) tasks)"
        }

        return "Running (1/\(orderedJobs.count) tasks)"
    }

    @ViewBuilder
    private var stateIconView: some View {
        if #available(macOS 14.0, *), !reduceMotion {
            Image(systemName: model.lastResultIconName)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, options: model.isActivityRunning ? .repeating : .default, value: model.isActivityRunning)
        } else {
            Image(systemName: model.lastResultIconName)
        }
    }

    var body: some View {
        HStack(spacing: 14) {
                HStack(spacing: 8) {
                    stateIconView
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(stateColor)
                        .frame(width: 20, height: 20, alignment: .center)
                Text(footerStateLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 140, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.activityText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let progress = model.activityProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Group {
                    if model.isActivityRunning {
                        Button(role: .destructive) {
                            model.stopCurrentActivity()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    } else if model.outputURL != nil {
                        Button("Show in Finder") {
                            model.revealOutput()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            adaptiveContainerFill(
                material: .regularMaterial,
                fallback: Color(nsColor: .windowBackgroundColor),
                reduceTransparency: reduceTransparency
            )
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(height: 0.5)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.lastActivityState)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.isActivityRunning)
    }
}

struct JobsPopoverView: View {
    @ObservedObject var model: WorkspaceViewModel
    @State private var hoveredJobID: UUID?

    private var sortedQueuedJobs: [QueuedClipExport] {
        model.queuedJobs.sorted(by: { $0.createdAt > $1.createdAt })
    }

    private var hasCompletedJobs: Bool {
        model.queuedJobs.contains(where: {
            $0.status == .completed || $0.status == .failed || $0.status == .cancelled
        })
    }

    private func queueStatusIconName(_ status: ClipExportQueueStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private func queueStatusColor(_ status: ClipExportQueueStatus) -> Color {
        switch status {
        case .queued: return .secondary
        case .running: return .accentColor
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    private func queueStatusLabel(_ status: ClipExportQueueStatus) -> String {
        switch status {
        case .queued: return "Queued"
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Jobs", systemImage: "list.bullet.rectangle.portrait")
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    model.clearCompletedQueuedJobs()
                } label: {
                    Label("Clear Completed", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!hasCompletedJobs)
            }

            Divider()

            if sortedQueuedJobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No jobs yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sortedQueuedJobs.enumerated()), id: \.element.id) { index, item in
                            HStack(alignment: .center, spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 8) {
                                        Image(systemName: queueStatusIconName(item.status))
                                            .foregroundStyle(queueStatusColor(item.status))
                                            .frame(width: 12)
                                        Text(item.summary)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                    }

                                    let detail = [item.subtitle, item.message].compactMap { value -> String? in
                                        guard let value, !value.isEmpty else { return nil }
                                        return value
                                    }.joined(separator: " • ")
                                    if !detail.isEmpty {
                                        Text(detail)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer(minLength: 8)

                                HStack(spacing: 6) {
                                    Text(queueStatusLabel(item.status))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    if item.status == .queued {
                                        Button("Cancel") {
                                            model.removeQueuedJob(item.id)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    } else if item.status == .failed || item.status == .cancelled {
                                        Button("Retry") {
                                            model.retryQueuedJob(item.id)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    } else if item.status == .completed, let outputURL = item.outputURL {
                                        Button {
                                            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                        } label: {
                                            Image(systemName: "magnifyingglass")
                                        }
                                        .help("Show in Finder")
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                }
                                .frame(width: 180, alignment: .trailing)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .frame(minHeight: 34)
                            .background(
                                Color.accentColor.opacity(hoveredJobID == item.id ? 0.08 : 0.0)
                            )
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering {
                                    hoveredJobID = item.id
                                } else if hoveredJobID == item.id {
                                    hoveredJobID = nil
                                }
                            }

                            if index < sortedQueuedJobs.count - 1 {
                                Divider()
                                    .opacity(0.5)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 560, height: 320, alignment: .topLeading)
    }
}

struct SegmentTimelineView: View {
    let blackSegments: [Segment]
    let silentSegments: [Segment]
    let profanitySegments: [Segment]
    let showBlackLane: Bool
    let showSilentLane: Bool
    let showProfanityLane: Bool
    let duration: Double

    @ViewBuilder
    private func lane(label: String, segments: [Segment], color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .fill(Color.gray.opacity(0.18))
                        .frame(height: 12)

                    ForEach(segments) { segment in
                        let safeDuration = max(duration, 0.001)
                        let startRatio = max(0, min(1, segment.start / safeDuration))
                        let widthRatio = max(0, min(1 - startRatio, segment.duration / safeDuration))
                        let x = geometry.size.width * startRatio
                        let w = max(2, geometry.size.width * widthRatio)

                        RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                            .fill(color)
                            .frame(width: w, height: 12)
                            .offset(x: x)
                    }
                }
            }
            .frame(height: 12)
        }
    }

    var body: some View {
        let hasVisibleLane = showBlackLane || showSilentLane || showProfanityLane

        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                if showBlackLane {
                    lane(label: "Black", segments: blackSegments, color: Color.black.opacity(0.9))
                }
                if showSilentLane {
                    lane(label: "Silence", segments: silentSegments, color: Color.orange.opacity(0.85))
                }
                if showProfanityLane {
                    lane(label: "Profanity", segments: profanitySegments, color: Color.red.opacity(0.9))
                }
            }

            if hasVisibleLane {
                HStack {
                    Text("00:00:00.000")
                        .padding(.leading, 72)
                    Spacer()
                    Text(formatSeconds(duration))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text("Run analysis to populate timeline lanes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct InlinePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

struct DetailView: View {
    let file: FileAnalysis
    let isCompactLayout: Bool
    @ObservedObject var model: WorkspaceViewModel

    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var hoveredBlackSegmentID: UUID?
    @State private var hoveredSilentSegmentID: UUID?
    @State private var hoveredProfanityHitID: UUID?

    private func loadPlayerItem() {
        let item = AVPlayerItem(url: file.fileURL)
        player.replaceCurrentItem(with: item)
        isPlaying = false
    }

    private func play(from time: Double) {
        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPlaying = true
    }

    private func jump(by seconds: Double) {
        let current = CMTimeGetSeconds(player.currentTime())
        let duration = CMTimeGetSeconds(player.currentItem?.duration ?? .invalid)
        let maxTime = (duration.isFinite && duration > 0) ? duration : max(0, current + seconds)
        let target = min(max(0, current + seconds), maxTime)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    @ViewBuilder
    private func analysisSections(showCopyButtons: Bool, showEmptySections: Bool = false) -> some View {
        let analysisHasRunOrIsRunning: Bool = {
            switch file.status {
            case .running, .done:
                return true
            case .idle, .failed:
                return false
            }
        }()

        if let timelineDuration = file.timelineDuration {
            SegmentTimelineView(
                blackSegments: file.includedBlackDetection ? file.segments : [],
                silentSegments: file.includedSilenceDetection ? file.silentSegments : [],
                profanitySegments: file.includedProfanityDetection ? file.profanityHits.map { Segment(start: $0.start, end: $0.end, duration: $0.duration) } : [],
                showBlackLane: analysisHasRunOrIsRunning && file.includedBlackDetection,
                showSilentLane: analysisHasRunOrIsRunning && file.includedSilenceDetection,
                showProfanityLane: analysisHasRunOrIsRunning && file.includedProfanityDetection,
                duration: timelineDuration
            )
        }

        if file.includedBlackDetection && (showEmptySections || !file.segments.isEmpty) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Black Segments")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if showCopyButtons {
                        Button("Copy Black List") {
                            copyToClipboard(file.formattedList)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if file.segments.isEmpty {
                    Text("No black segments detected yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(file.segments) { segment in
                                HStack {
                                    Text(formatSeconds(segment.start))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                    Text("→")
                                        .foregroundStyle(.secondary)
                                    Text(formatSeconds(segment.end))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                    Spacer()
                                    Text(String(format: "%.3fs", segment.duration))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                        .fill(hoveredBlackSegmentID == segment.id ? Color.accentColor.opacity(0.16) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                        .stroke(
                                            hoveredBlackSegmentID == segment.id ? Color.accentColor.opacity(0.26) : Color.primary.opacity(0.045),
                                            lineWidth: hoveredBlackSegmentID == segment.id ? 0.9 : 0.4
                                        )
                                )
                                .contentShape(Rectangle())
                                .onHover { isHovering in
                                    hoveredBlackSegmentID = isHovering ? segment.id : (hoveredBlackSegmentID == segment.id ? nil : hoveredBlackSegmentID)
                                }
                                .onTapGesture(count: 2) {
                                    play(from: segment.start)
                                }
                                .help("Double-click to play from this segment start")
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }

        if file.includedSilenceDetection && (showEmptySections || !file.silentSegments.isEmpty) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Silent Gaps (> \(String(format: "%.1f", file.silenceMinDurationSeconds))s)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if showCopyButtons {
                        Button("Copy Silence List") {
                            copyToClipboard(file.formattedSilentList)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if file.silentSegments.isEmpty {
                    Text("No silent gaps detected yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(file.silentSegments) { segment in
                                HStack {
                                    Text(formatSeconds(segment.start))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                    Text("→")
                                        .foregroundStyle(.secondary)
                                    Text(formatSeconds(segment.end))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                    Spacer()
                                    Text(String(format: "%.3fs", segment.duration))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                        .fill(hoveredSilentSegmentID == segment.id ? Color.accentColor.opacity(0.16) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                        .stroke(
                                            hoveredSilentSegmentID == segment.id ? Color.accentColor.opacity(0.26) : Color.primary.opacity(0.045),
                                            lineWidth: hoveredSilentSegmentID == segment.id ? 0.9 : 0.4
                                        )
                                )
                                .contentShape(Rectangle())
                                .onHover { isHovering in
                                    hoveredSilentSegmentID = isHovering ? segment.id : (hoveredSilentSegmentID == segment.id ? nil : hoveredSilentSegmentID)
                                }
                                .onTapGesture(count: 2) {
                                    play(from: segment.start)
                                }
                                .help("Double-click to play from this silent-gap start")
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }

        if file.includedProfanityDetection && (showEmptySections || !file.profanityHits.isEmpty) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Profanity Hits")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if showCopyButtons {
                        Button("Copy Profanity List") {
                            copyToClipboard(file.formattedProfanityList)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if file.profanityHits.isEmpty {
                    Text("No profanity detected yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(file.profanityHits) { hit in
                                HStack {
                                    Text(formatSeconds(hit.start))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                    Text("→")
                                        .foregroundStyle(.secondary)
                                    Text(formatSeconds(hit.end))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                    Spacer()
                                    Text(hit.word)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                        .fill(hoveredProfanityHitID == hit.id ? Color.accentColor.opacity(0.16) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                        .stroke(
                                            hoveredProfanityHitID == hit.id ? Color.accentColor.opacity(0.26) : Color.primary.opacity(0.045),
                                            lineWidth: hoveredProfanityHitID == hit.id ? 0.9 : 0.4
                                        )
                                )
                                .contentShape(Rectangle())
                                .onHover { isHovering in
                                    hoveredProfanityHitID = isHovering ? hit.id : (hoveredProfanityHitID == hit.id ? nil : hoveredProfanityHitID)
                                }
                                .onTapGesture(count: 2) {
                                    play(from: hit.start)
                                }
                                .help("Double-click to play from this profanity hit")
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(file.fileURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if model.hasVideoTrack {
                InlinePlayerView(player: player)
                    .frame(
                        minHeight: isCompactLayout ? 150 : 260,
                        maxHeight: isCompactLayout ? 210 : 320
                    )
                    .clipShape(RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                    Text("Audio-only source")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous))
            }

            HStack {
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        jump(by: -Double(model.jumpIntervalSeconds))
                    } label: {
                        Label("Back \(model.jumpIntervalSeconds)s", systemImage: "gobackward")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        togglePlayPause()
                    } label: {
                        Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        jump(by: Double(model.jumpIntervalSeconds))
                    } label: {
                        Label("Forward \(model.jumpIntervalSeconds)s", systemImage: "goforward")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                Spacer()
            }

            switch file.status {
            case .running:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(model.analyzeStatusText.isEmpty ? "Preparing analysis…" : model.analyzeStatusText)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Spacer()
                    }

                    if !file.segments.isEmpty || !file.silentSegments.isEmpty || !file.profanityHits.isEmpty {
                        Text("Detections so far")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        if !file.segments.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Black segments: \(file.segments.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(Array(file.segments.suffix(8))) { segment in
                                    Text(segment.formatted)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if !file.silentSegments.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Silent gaps: \(file.silentSegments.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(Array(file.silentSegments.suffix(8))) { segment in
                                    Text(segment.formatted)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if !file.profanityHits.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Profanity hits: \(file.profanityHits.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(Array(file.profanityHits.suffix(8))) { hit in
                                    Text(hit.formatted)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                analysisSections(showCopyButtons: false, showEmptySections: true)
            case .failed(let reason):
                Text("Analysis failed: \(reason)")
                    .foregroundStyle(.red)
            case .idle:
                Text("Ready to analyze")
                    .foregroundStyle(.secondary)
            case .done:
                VStack(alignment: .leading, spacing: 4) {
                    if file.includedBlackDetection {
                        if file.segments.isEmpty {
                            Label("No black segments detected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Black segments detected: \(file.segments.count)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    if file.includedSilenceDetection {
                        if file.silentSegments.isEmpty {
                            Label("No silent gaps detected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Silent gaps detected: \(file.silentSegments.count)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    if file.includedProfanityDetection {
                        if file.profanityHits.isEmpty {
                            Label("No profanity detected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Profanity hits detected: \(file.profanityHits.count)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                analysisSections(showCopyButtons: true)
            }

            Spacer()
        }
        .padding(16)
        .onAppear {
            loadPlayerItem()
        }
        .onChange(of: file.fileURL.path) { _ in
            loadPlayerItem()
        }
        .onDisappear {
            player.pause()
        }
    }
}

