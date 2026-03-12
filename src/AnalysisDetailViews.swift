import SwiftUI
import AppKit
import AVKit

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
