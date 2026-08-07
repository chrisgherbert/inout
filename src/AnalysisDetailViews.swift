import SwiftUI
import AppKit
import AVKit

struct SegmentTimelineView: View {
    let blackSegments: [Segment]
    let badEditSegments: [Segment]
    let silentSegments: [Segment]
    let profanitySegments: [Segment]
    let showBlackLane: Bool
    let showBadEditLane: Bool
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
        let hasVisibleLane = showBlackLane || showBadEditLane || showSilentLane || showProfanityLane

        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                if showBlackLane {
                    lane(label: "Black", segments: blackSegments, color: Color.black.opacity(0.9))
                }
                if showBadEditLane {
                    lane(label: "Bad Edits", segments: badEditSegments, color: Color.cyan.opacity(0.9))
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
                    DisplayTimecodeText(seconds: 0)
                        .padding(.leading, 72)
                    Spacer()
                    DisplayTimecodeText(seconds: duration)
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
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

struct DetailView: View {
    let file: FileAnalysis
    let isCompactLayout: Bool
    @ObservedObject var model: WorkspaceViewModel
    @ObservedObject var activity: ActivityPresentationModel
    @Environment(\.timecodeDisplayStyle) private var timecodeDisplayStyle
    @Environment(\.timecodeFrameRate) private var timecodeFrameRate
    @Environment(\.timecodeMediaDuration) private var timecodeMediaDuration

    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var hoveredBlackSegmentID: UUID?
    @State private var hoveredBadEditIssueID: UUID?
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

    private func seek(to time: Double) {
        player.seek(
            to: CMTime(seconds: max(0, time), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func displayTimecode(_ seconds: Double) -> String {
        formatDisplayTimecode(
            seconds,
            style: timecodeDisplayStyle,
            frameRate: timecodeFrameRate,
            mediaDuration: timecodeMediaDuration
        )
    }

    private var formattedBlackList: String {
        file.segments.map {
            "\(displayTimecode($0.start)) → \(displayTimecode($0.end)) (\(String(format: "%.3f", $0.duration))s)"
        }.joined(separator: "\n")
    }

    private var formattedSilentList: String {
        file.silentSegments.map {
            "\(displayTimecode($0.start)) → \(displayTimecode($0.end)) (\(String(format: "%.3f", $0.duration))s)"
        }.joined(separator: "\n")
    }

    private var formattedProfanityList: String {
        file.profanityHits.map {
            "\(displayTimecode($0.start)) → \(displayTimecode($0.end)) (\($0.word))"
        }.joined(separator: "\n")
    }

    private var formattedBadEditList: String {
        file.badEditIssues.map {
            "\(displayTimecode($0.start)) -> \(displayTimecode($0.end))  \($0.title): \($0.detail)"
        }.joined(separator: "\n")
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
                badEditSegments: file.includedBadEditDetection ? file.badEditIssues.map {
                    Segment(start: $0.start, end: $0.end, duration: max($0.duration, 0.04))
                } : [],
                silentSegments: file.includedSilenceDetection ? file.silentSegments : [],
                profanitySegments: file.includedProfanityDetection ? file.profanityHits.map { Segment(start: $0.start, end: $0.end, duration: $0.duration) } : [],
                showBlackLane: analysisHasRunOrIsRunning && file.includedBlackDetection,
                showBadEditLane: analysisHasRunOrIsRunning && file.includedBadEditDetection,
                showSilentLane: analysisHasRunOrIsRunning && file.includedSilenceDetection,
                showProfanityLane: analysisHasRunOrIsRunning && file.includedProfanityDetection,
                duration: timelineDuration
            )
        }

        if file.includedBadEditDetection && (showEmptySections || !file.badEditIssues.isEmpty) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Possible Bad Edits")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if showCopyButtons {
                        Button("Copy Findings") {
                            copyToClipboard(formattedBadEditList)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if file.badEditIssues.isEmpty {
                    Text("No possible bad edits detected yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(file.badEditIssues.sorted { $0.start < $1.start }) { issue in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: issue.confidence == .high ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                                        .foregroundStyle(issue.confidence == .high ? Color.orange : Color.secondary)
                                        .frame(width: 16)
                                    DisplayTimecodeText(seconds: issue.start)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 112, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(issue.title)
                                                .font(.body.weight(.medium))
                                            Text(issue.confidence.rawValue.capitalized)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(issue.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                        .fill(hoveredBadEditIssueID == issue.id ? Color.cyan.opacity(0.12) : Color.clear)
                                )
                                .contentShape(Rectangle())
                                .onHover { isHovering in
                                    hoveredBadEditIssueID = isHovering ? issue.id : (hoveredBadEditIssueID == issue.id ? nil : hoveredBadEditIssueID)
                                }
                                .gesture(
                                    TapGesture(count: 2)
                                        .onEnded { play(from: max(0, issue.start - 2)) }
                                        .exclusively(
                                            before: TapGesture()
                                                .onEnded { seek(to: issue.start) }
                                        )
                                )
                                .help("Click to seek; double-click to play with two seconds of context")
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }
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
                            copyToClipboard(formattedBlackList)
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
                                    DisplayTimecodeText(seconds: segment.start)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                    Text("→")
                                        .foregroundStyle(.secondary)
                                    DisplayTimecodeText(seconds: segment.end)
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
                            copyToClipboard(formattedSilentList)
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
                                SilentGapResultRow(
                                    segment: segment,
                                    hoveredSegmentID: $hoveredSilentSegmentID,
                                    play: play
                                )
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
                            copyToClipboard(formattedProfanityList)
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
                                ProfanityHitResultRow(
                                    hit: hit,
                                    hoveredHitID: $hoveredProfanityHitID,
                                    play: play
                                )
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
                            Text(activity.analyzeStatusText.isEmpty ? "Preparing analysis…" : activity.analyzeStatusText)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Spacer()
                    }

                    if !file.segments.isEmpty || !file.badEditIssues.isEmpty || !file.silentSegments.isEmpty || !file.profanityHits.isEmpty {
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

                        if !file.badEditIssues.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Possible bad edits: \(file.badEditIssues.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(Array(file.badEditIssues.suffix(8))) { issue in
                                    Text(issue.formatted)
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
                    if file.includedBadEditDetection {
                        if file.badEditIssues.isEmpty {
                            Label("No possible bad edits detected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Possible bad edits detected: \(file.badEditIssues.count)", systemImage: "exclamationmark.triangle.fill")
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

private struct SilentGapResultRow: View {
    let segment: Segment
    @Binding var hoveredSegmentID: UUID?
    let play: (Double) -> Void

    private var isHovered: Bool {
        hoveredSegmentID == segment.id
    }

    var body: some View {
        HStack {
            DisplayTimecodeText(seconds: segment.start)
                .font(.system(.body, design: .monospaced))
                .frame(width: 130, alignment: .leading)
            Text("→")
                .foregroundStyle(.secondary)
            DisplayTimecodeText(seconds: segment.end)
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
                .fill(isHovered ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                .stroke(
                    isHovered ? Color.accentColor.opacity(0.26) : Color.primary.opacity(0.045),
                    lineWidth: isHovered ? 0.9 : 0.4
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredSegmentID = isHovering ? segment.id : (isHovered ? nil : hoveredSegmentID)
        }
        .onTapGesture(count: 2) {
            play(segment.start)
        }
        .help("Double-click to play from this silent-gap start")
    }
}

private struct ProfanityHitResultRow: View {
    let hit: ProfanityHit
    @Binding var hoveredHitID: UUID?
    let play: (Double) -> Void

    private var isHovered: Bool {
        hoveredHitID == hit.id
    }

    var body: some View {
        HStack {
            DisplayTimecodeText(seconds: hit.start)
                .font(.system(.body, design: .monospaced))
                .frame(width: 130, alignment: .leading)
            Text("→")
                .foregroundStyle(.secondary)
            DisplayTimecodeText(seconds: hit.end)
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
                .fill(isHovered ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                .stroke(
                    isHovered ? Color.accentColor.opacity(0.26) : Color.primary.opacity(0.045),
                    lineWidth: isHovered ? 0.9 : 0.4
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredHitID = isHovering ? hit.id : (isHovered ? nil : hoveredHitID)
        }
        .onTapGesture(count: 2) {
            play(hit.start)
        }
        .help("Double-click to play from this profanity hit")
    }
}
