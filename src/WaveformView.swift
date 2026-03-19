import AVFoundation
import SwiftUI

struct WaveformView: View {
    let player: AVPlayer
    @Environment(\.colorScheme) private var colorScheme
    let sourceSessionID: UUID
    let samples: [Double]
    let zoomLevel: Double
    let renderBuckets: [Double]
    let startSeconds: Double
    let visualPlayheadSeconds: Double
    let playheadJumpFromSeconds: Double
    let playheadJumpAnimationToken: Int
    let endSeconds: Double
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let captureMarkers: [CaptureTimelineMarker]
    let highlightedMarkerID: UUID?
    let highlightedClipBoundary: ClipBoundaryHighlight?
    let captureFrameFlashToken: Int
    let quickExportFlashToken: Int
    let onSeek: (Double, Bool) -> Void
    let onPlayheadDragEdgePan: (CGFloat, CGFloat) -> Void
    let onPlayheadDragStateChanged: (Bool) -> Void
    let onClipBoundaryDragStateChanged: (Bool) -> Void
    let onSetStart: (Double) -> Void
    let onSetEnd: (Double) -> Void
    let onHoverChanged: (Bool) -> Void
    let onPointerTimeChanged: (Double?) -> Void
    let onHostViewAvailable: (WaveformRasterHostView) -> Void

    @State private var isPlayheadCaptureFlashing = false

    var body: some View {
        WaveformRasterLayerView(
            player: player,
            sourceSessionID: sourceSessionID,
            samples: samples,
            zoomLevel: zoomLevel,
            renderBuckets: renderBuckets,
            clipStartSeconds: startSeconds,
            clipEndSeconds: endSeconds,
            totalDurationSeconds: totalDurationSeconds,
            visibleStartSeconds: visibleStartSeconds,
            visibleEndSeconds: visibleEndSeconds,
            isDarkAppearance: colorScheme == .dark,
            playheadSeconds: visualPlayheadSeconds,
            playheadJumpFromSeconds: playheadJumpFromSeconds,
            playheadJumpAnimationToken: playheadJumpAnimationToken,
            isPlayheadCaptureFlashing: isPlayheadCaptureFlashing,
            captureMarkers: captureMarkers,
            highlightedMarkerID: highlightedMarkerID,
            highlightedClipBoundary: highlightedClipBoundary,
            quickExportFlashToken: quickExportFlashToken,
            onMarkerSeek: { seconds in
                onSeek(seconds, true)
            },
            onInteractiveSeek: onSeek,
            onPlayheadDragStateChanged: onPlayheadDragStateChanged,
            onClipBoundaryDragStateChanged: onClipBoundaryDragStateChanged,
            onPlayheadDragEdgePan: onPlayheadDragEdgePan,
            onSetStart: onSetStart,
            onSetEnd: onSetEnd,
            onHoverChanged: onHoverChanged,
            onPointerTimeChanged: onPointerTimeChanged,
            onHostViewAvailable: onHostViewAvailable
        )
        .overlay(alignment: .bottomLeading) {
            Text(formatSeconds(visibleStartSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.9))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.black.opacity(0.78))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                )
                .padding(.leading, 6)
                .padding(.bottom, 4)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            Text(formatSeconds(visibleEndSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.9))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.black.opacity(0.78))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                )
                .padding(.trailing, 6)
                .padding(.bottom, 4)
                .allowsHitTesting(false)
        }
        .task(id: captureFrameFlashToken) {
            guard captureFrameFlashToken > 0 else { return }
            withAnimation(.easeOut(duration: 0.08)) {
                isPlayheadCaptureFlashing = true
            }
            try? await Task.sleep(nanoseconds: 220_000_000)
            withAnimation(.easeOut(duration: 0.2)) {
                isPlayheadCaptureFlashing = false
            }
        }
    }
}
