import SwiftUI
import AppKit
import AVFoundation

struct ClipSelectionPanel: View, Equatable {
    @State private var isTimecodeRowHovered = false
    let player: AVPlayer
    let sourceSessionID: UUID
    let clipStartSeconds: Double
    let clipEndSeconds: Double
    let clipDurationSeconds: Double
    let hasVideoTrack: Bool
    let timelinePanelHeight: CGFloat
    let thumbnailStripHeight: CGFloat
    @Binding var clipStartText: String
    @Binding var clipEndText: String
    let onCommitClipStartText: () -> Void
    let onCommitClipEndText: () -> Void
    let isCompactLayout: Bool
    let reduceTransparency: Bool
    let isWaveformLoading: Bool
    let waveformSamples: [Double]
    let thumbnailTiles: [TimelineThumbnailTile]
    let thumbnailTilesRevision: Int
    let thumbnailStripImage: CGImage?
    let thumbnailStripRevision: Int
    let thumbnailStripShouldCrossfade: Bool
    let isThumbnailStripLoading: Bool
    let thumbnailStripSourceStartSeconds: Double
    let thumbnailStripSourceEndSeconds: Double
    let thumbnailStripSourceVisibleDurationSeconds: Double
    let allowedTimelineZoomLevels: [Double]
    let timelineZoom: Double
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let playheadVisualSeconds: Double
    let playheadJumpFromSeconds: Double
    let playheadJumpAnimationToken: Int
    let playheadSeconds: Double
    let playheadCopyFlash: Bool
    let captureMarkers: [CaptureTimelineMarker]
    let highlightedMarkerID: UUID?
    let highlightedClipBoundary: ClipBoundaryHighlight?
    let captureFrameFlashToken: Int
    let quickExportFlashToken: Int
    let onTimelineWidthChanged: (CGFloat) -> Void
    let onSeek: (Double, Bool) -> Void
    let onPlayheadDragEdgePan: (CGFloat, CGFloat) -> Void
    let onPlayheadDragStateChanged: (Bool) -> Void
    let onClipBoundaryDragStateChanged: (Bool) -> Void
    let onSetStart: (Double) -> Void
    let onSetEnd: (Double) -> Void
    let onWaveformHoverChanged: (Bool) -> Void
    let onWaveformPointerTimeChanged: (Double?) -> Void
    let onWaveformHostViewAvailable: (WaveformRasterHostView) -> Void
    let onTimelineHoverChanged: (Bool) -> Void
    let onCopyPlayheadTimecode: () -> Void
    let onJumpToStart: () -> Void
    let onJumpToEnd: () -> Void
    let onCaptureFrame: () -> Void

    static func == (lhs: ClipSelectionPanel, rhs: ClipSelectionPanel) -> Bool {
        lhs.sourceSessionID == rhs.sourceSessionID &&
        abs(lhs.clipStartSeconds - rhs.clipStartSeconds) < 0.0001 &&
        abs(lhs.clipEndSeconds - rhs.clipEndSeconds) < 0.0001 &&
        abs(lhs.clipDurationSeconds - rhs.clipDurationSeconds) < 0.0001 &&
        lhs.hasVideoTrack == rhs.hasVideoTrack &&
        abs(lhs.timelinePanelHeight - rhs.timelinePanelHeight) < 0.0001 &&
        abs(lhs.thumbnailStripHeight - rhs.thumbnailStripHeight) < 0.0001 &&
        lhs.isCompactLayout == rhs.isCompactLayout &&
        lhs.reduceTransparency == rhs.reduceTransparency &&
        lhs.isWaveformLoading == rhs.isWaveformLoading &&
        lhs.waveformSamples.count == rhs.waveformSamples.count &&
        lhs.thumbnailTilesRevision == rhs.thumbnailTilesRevision &&
        lhs.thumbnailStripRevision == rhs.thumbnailStripRevision &&
        lhs.thumbnailStripShouldCrossfade == rhs.thumbnailStripShouldCrossfade &&
        lhs.isThumbnailStripLoading == rhs.isThumbnailStripLoading &&
        abs(lhs.thumbnailStripSourceStartSeconds - rhs.thumbnailStripSourceStartSeconds) < 0.0001 &&
        abs(lhs.thumbnailStripSourceEndSeconds - rhs.thumbnailStripSourceEndSeconds) < 0.0001 &&
        abs(lhs.thumbnailStripSourceVisibleDurationSeconds - rhs.thumbnailStripSourceVisibleDurationSeconds) < 0.0001 &&
        lhs.allowedTimelineZoomLevels == rhs.allowedTimelineZoomLevels &&
        abs(lhs.timelineZoom - rhs.timelineZoom) < 0.0001 &&
        abs(lhs.totalDurationSeconds - rhs.totalDurationSeconds) < 0.0001 &&
        abs(lhs.visibleStartSeconds - rhs.visibleStartSeconds) < 0.0001 &&
        abs(lhs.visibleEndSeconds - rhs.visibleEndSeconds) < 0.0001 &&
        abs(lhs.playheadVisualSeconds - rhs.playheadVisualSeconds) < 0.0001 &&
        abs(lhs.playheadJumpFromSeconds - rhs.playheadJumpFromSeconds) < 0.0001 &&
        lhs.playheadJumpAnimationToken == rhs.playheadJumpAnimationToken &&
        abs(lhs.playheadSeconds - rhs.playheadSeconds) < 0.0001 &&
        lhs.playheadCopyFlash == rhs.playheadCopyFlash &&
        lhs.captureMarkers == rhs.captureMarkers &&
        lhs.highlightedMarkerID == rhs.highlightedMarkerID &&
        lhs.highlightedClipBoundary == rhs.highlightedClipBoundary &&
        lhs.captureFrameFlashToken == rhs.captureFrameFlashToken &&
        lhs.quickExportFlashToken == rhs.quickExportFlashToken
    }

    var body: some View {
        let _ = PlayheadDiagnostics.shared.noteSelectionPanelBodyEvaluation()
        VStack(alignment: .leading, spacing: 10) {
            if totalDurationSeconds > 0 || !waveformSamples.isEmpty || hasVideoTrack {
                ZStack {
                    WaveformView(
                        player: player,
                        sourceSessionID: sourceSessionID,
                        samples: waveformSamples,
                        zoomLevel: timelineZoom,
                        renderBuckets: allowedTimelineZoomLevels,
                        startSeconds: clipStartSeconds,
                        visualPlayheadSeconds: playheadVisualSeconds,
                        playheadJumpFromSeconds: playheadJumpFromSeconds,
                        playheadJumpAnimationToken: playheadJumpAnimationToken,
                        endSeconds: clipEndSeconds,
                        totalDurationSeconds: totalDurationSeconds,
                        visibleStartSeconds: visibleStartSeconds,
                        visibleEndSeconds: visibleEndSeconds,
                        captureMarkers: captureMarkers,
                        highlightedMarkerID: highlightedMarkerID,
                        highlightedClipBoundary: highlightedClipBoundary,
                        captureFrameFlashToken: captureFrameFlashToken,
                        quickExportFlashToken: quickExportFlashToken,
                        showsThumbnailStrip: hasVideoTrack && thumbnailStripHeight > 0,
                        thumbnailStripHeight: thumbnailStripHeight,
                        thumbnailTiles: thumbnailTiles,
                        thumbnailTilesRevision: thumbnailTilesRevision,
                        thumbnailStripImage: thumbnailStripImage,
                        thumbnailStripRevision: thumbnailStripRevision,
                        thumbnailStripShouldCrossfade: thumbnailStripShouldCrossfade,
                        isThumbnailStripLoading: isThumbnailStripLoading,
                        thumbnailStripSourceStartSeconds: thumbnailStripSourceStartSeconds,
                        thumbnailStripSourceEndSeconds: thumbnailStripSourceEndSeconds,
                        thumbnailStripSourceVisibleDurationSeconds: thumbnailStripSourceVisibleDurationSeconds,
                        onSeek: onSeek,
                        onPlayheadDragEdgePan: onPlayheadDragEdgePan,
                        onPlayheadDragStateChanged: onPlayheadDragStateChanged,
                        onClipBoundaryDragStateChanged: onClipBoundaryDragStateChanged,
                        onSetStart: onSetStart,
                        onSetEnd: onSetEnd,
                        onHoverChanged: onWaveformHoverChanged,
                        onPointerTimeChanged: onWaveformPointerTimeChanged,
                        onHostViewAvailable: onWaveformHostViewAvailable
                    )

                    if isWaveformLoading {
                        WaveformLoadingPlaceholder(
                            hasVideoTrack: hasVideoTrack,
                            isCompactLayout: isCompactLayout,
                            reduceTransparency: reduceTransparency
                        )
                        .allowsHitTesting(false)
                    }
                }
                .frame(height: timelinePanelHeight)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .padding(.bottom, -6)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { onTimelineWidthChanged(geo.size.width) }
                            .onChange(of: geo.size.width) { width in
                                onTimelineWidthChanged(width)
                            }
                    }
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("In")
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .leading)
                        TextField("00:00:00.000", text: $clipStartText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 140)
                            .onSubmit { onCommitClipStartText() }
                        Button("Set In") { onSetStart(playheadSeconds) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    Divider()
                        .frame(height: 22)
                        .padding(.horizontal, 10)

                    HStack(spacing: 4) {
                        Text("Out")
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .leading)
                        TextField("00:00:00.000", text: $clipEndText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 140)
                            .onSubmit { onCommitClipEndText() }
                        Button("Set Out") { onSetEnd(playheadSeconds) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .font(.caption)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("In")
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .leading)
                        TextField("00:00:00.000", text: $clipStartText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit { onCommitClipStartText() }
                        Button("Set In") { onSetStart(playheadSeconds) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    HStack(spacing: 8) {
                        Text("Out")
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .leading)
                        TextField("00:00:00.000", text: $clipEndText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit { onCommitClipEndText() }
                        Button("Set Out") { onSetEnd(playheadSeconds) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .center)

        }
        .onHover(perform: onTimelineHoverChanged)
    }
}

private struct WaveformLoadingPlaceholder: View {
    let hasVideoTrack: Bool
    let isCompactLayout: Bool
    let reduceTransparency: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(reduceTransparency ? 0.045 : 0.04),
                                Color.white.opacity(reduceTransparency ? 0.03 : 0.022)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.05), lineWidth: 0.6)
                    )

                HStack(spacing: 8) {
                    Image(systemName: hasVideoTrack ? "film.stack.fill" : "waveform")
                        .font(.system(size: isCompactLayout ? 15 : 17, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.95))
                    Text(hasVideoTrack ? "Generating timeline previews…" : "Generating waveform…")
                        .font(.system(size: isCompactLayout ? 12.5 : 13.5, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.88))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(reduceTransparency ? 0.16 : 0.22))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.6)
                )
            }
            .frame(height: geo.size.height)
            .overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                    let elapsed = context.date.timeIntervalSinceReferenceDate
                    let pulse = 0.5 + (0.5 * sin(elapsed * .pi * 1.45))
                    let backgroundOpacity = reduceTransparency ? (0.024 + (pulse * 0.024)) : (0.02 + (pulse * 0.032))
                    let borderOpacity = reduceTransparency ? (0.12 + (pulse * 0.11)) : (0.1 + (pulse * 0.16))

                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(backgroundOpacity))

                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(borderOpacity), lineWidth: 1.1)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
    }
}
