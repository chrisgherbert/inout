import AppKit
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
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
    let onSetStart: (Double) -> Void
    let onSetEnd: (Double) -> Void
    let onHoverChanged: (Bool) -> Void
    let onPointerTimeChanged: (Double?) -> Void
    @State private var didStartPlayheadDrag = false
    @State private var isHovered = false
    @State private var isStartEdgeHovered = false
    @State private var isEndEdgeHovered = false
    @State private var isStartEdgeDragging = false
    @State private var isEndEdgeDragging = false
    @State private var startEdgeDragAnchor: Double?
    @State private var endEdgeDragAnchor: Double?
    @State private var isPlayheadCaptureFlashing = false
    @State private var selectionFlashOpacity: Double = 0
    @State private var selectionFlashGlowOpacity: Double = 0
    @State private var isResizeCursorActive = false
    @State private var markerSnapLockSeconds: Double?

    private var visibleDuration: Double {
        max(0.0001, visibleEndSeconds - visibleStartSeconds)
    }

    private func xPosition(for value: Double, width: CGFloat) -> CGFloat {
        let local = value - visibleStartSeconds
        return CGFloat(local / visibleDuration) * width
    }

    private func timeValue(for x: CGFloat, width: CGFloat, windowStart: Double, windowEnd: Double) -> Double {
        guard width > 0 else { return 0 }
        let ratio = min(max(0, x / width), 1.0)
        let duration = max(0.0001, windowEnd - windowStart)
        return min(totalDurationSeconds, max(0, windowStart + (Double(ratio) * duration)))
    }

    private func snapToPixel(_ value: CGFloat) -> CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixel = CGFloat(1.0 / scale)
        return (value / pixel).rounded() * pixel
    }

    private var systemAccent: Color {
        Color(nsColor: .controlAccentColor)
    }

    private func rulerMajorStep(for visibleDuration: Double) -> Double {
        let candidates: [Double] = [
            1.0 / 30.0, 1.0 / 15.0, 0.1, 0.2, 0.5,
            1, 2, 5, 10, 15, 30, 60, 120, 300, 600
        ]
        for step in candidates where (visibleDuration / step) <= 10 {
            return step
        }
        return candidates.last ?? 600
    }

    private func rulerMinorDivisions(for majorStep: Double) -> Int {
        if majorStep >= 60 { return 6 }
        if majorStep >= 1 { return 5 }
        return 2
    }

    private func rulerLabel(for seconds: Double, majorStep: Double) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = whole % 60
        if majorStep < 1 {
            let centiseconds = Int(((clamped - floor(clamped)) * 100).rounded())
            if hours > 0 {
                return String(format: "%d:%02d:%02d.%02d", hours, minutes, secs, centiseconds)
            }
            return String(format: "%02d:%02d.%02d", minutes, secs, centiseconds)
        }
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func makeRulerTicks(
        visibleStart: Double,
        visibleEnd: Double,
        width: CGFloat,
        majorStep: Double,
        minorStep: Double
    ) -> (minor: [CGFloat], major: [(x: CGFloat, seconds: Double)]) {
        let duration = max(0.0001, visibleEnd - visibleStart)
        func xPosition(for value: Double) -> CGFloat {
            let local = value - visibleStart
            return CGFloat(local / duration) * width
        }

        let epsilon = minorStep * 0.001
        var minorTicks: [CGFloat] = []
        var majorTicks: [(x: CGFloat, seconds: Double)] = []
        var t = floor(visibleStart / minorStep) * minorStep
        var guardCount = 0
        while t <= (visibleEnd + minorStep) && guardCount < 10_000 {
            let x = xPosition(for: t)
            if x >= -1 && x <= width + 1 {
                let majorRatio = t / majorStep
                if abs(majorRatio - majorRatio.rounded()) <= epsilon {
                    majorTicks.append((x: x, seconds: t))
                } else {
                    minorTicks.append(x)
                }
            }
            t += minorStep
            guardCount += 1
        }
        return (minorTicks, majorTicks)
    }

    private func filterLabeledMajorTicks(
        _ majorTicks: [(x: CGFloat, seconds: Double)],
        minLabelSpacing: CGFloat = 72
    ) -> [(x: CGFloat, seconds: Double)] {
        var labeled: [(x: CGFloat, seconds: Double)] = []
        var lastX = -CGFloat.greatestFiniteMagnitude
        for tick in majorTicks where tick.x - lastX >= minLabelSpacing {
            labeled.append(tick)
            lastX = tick.x
        }
        return labeled
    }

    private func markerNearX(_ x: CGFloat, width: CGFloat) -> Double? {
        let markerHitTolerance: CGFloat = 12
        let visibleMarkers = captureMarkers.filter { marker in
            marker.seconds >= visibleStartSeconds && marker.seconds <= visibleEndSeconds
        }
        var best: (seconds: Double, distance: CGFloat)?
        for marker in visibleMarkers {
            let markerX = snapToPixel(xPosition(for: marker.seconds, width: width))
            let distance = abs(markerX - x)
            guard distance <= markerHitTolerance else { continue }
            if let current = best {
                if distance < current.distance {
                    best = (marker.seconds, distance)
                }
            } else {
                best = (marker.seconds, distance)
            }
        }
        return best?.seconds
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let rulerHeight: CGFloat = 16
            let rulerGap: CGFloat = 2
            let markerTopGutter: CGFloat = 8
            let markerBottomGutter: CGFloat = 8
            let timelineVerticalOffset: CGFloat = rulerHeight + rulerGap + markerTopGutter
            let timelineHeight = max(1, height - rulerHeight - rulerGap - markerTopGutter - markerBottomGutter)
            let startX = xPosition(for: startSeconds, width: width)
            let endX = xPosition(for: endSeconds, width: width)
            let selectionStartX = min(startX, endX)
            let selectionEndX = max(startX, endX)
            // Draw only the viewport intersection. This keeps geometry stable at high
            // zoom levels even when the logical clip range spans far outside view.
            let drawSelectionStartX = max(0, selectionStartX)
            let drawSelectionEndX = min(width, selectionEndX)
            let drawSelectionWidth = max(0, drawSelectionEndX - drawSelectionStartX)
            let hasSelection = drawSelectionWidth > 0.5
            let isStartEdgeActive = isStartEdgeHovered || isStartEdgeDragging
            let isEndEdgeActive = isEndEdgeHovered || isEndEdgeDragging
            let isEdgeActive = isStartEdgeActive || isEndEdgeActive
            let edgeHoverProximity: CGFloat = 22
            let edgeHitWidth: CGFloat = edgeHoverProximity * 2
            let edgeVisibilityMargin: CGFloat = max(edgeHitWidth, 36)
            let startEdgeVisible = startX >= -edgeVisibilityMargin && startX <= (width + edgeVisibilityMargin)
            let endEdgeVisible = endX >= -edgeVisibilityMargin && endX <= (width + edgeVisibilityMargin)
            let selectionOutlineOpacity: Double = isEdgeActive ? 1.0 : (isHovered ? 0.98 : 0.92)
            let selectionOutlineWidth: CGFloat = isEdgeActive ? 3.4 : 3.0
            let edgeGlowWidth = min(max(drawSelectionWidth * 0.18, 18), 44)
            let startEdgeGlowOpacity: Double = isStartEdgeDragging ? 1.0 : (isStartEdgeHovered ? 0.78 : 0)
            let endEdgeGlowOpacity: Double = isEndEdgeDragging ? 1.0 : (isEndEdgeHovered ? 0.78 : 0)
            let startBoundaryPulseOpacity: Double = highlightedClipBoundary == .start ? 0.95 : 0
            let endBoundaryPulseOpacity: Double = highlightedClipBoundary == .end ? 0.95 : 0
            let majorStep = rulerMajorStep(for: visibleDuration)
            let minorDivisions = max(1, rulerMinorDivisions(for: majorStep))
            let minorStep = majorStep / Double(minorDivisions)
            let ticks = makeRulerTicks(
                visibleStart: visibleStartSeconds,
                visibleEnd: visibleEndSeconds,
                width: width,
                majorStep: majorStep,
                minorStep: minorStep
            )
            let minorTicks = ticks.minor
            let majorTicks = ticks.major
            let labeledMajorTicks = filterLabeledMajorTicks(majorTicks)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    .fill(Color.black.opacity(isHovered ? 0.16 : 0.12))

                // Dedicated ruler lane for time ticks/labels above the waveform.
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: width, height: rulerHeight)
                    .overlay(alignment: .bottomLeading) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.10))
                            .frame(height: 0.8)
                    }
                    .overlay(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(minorTicks.enumerated()), id: \.offset) { tick in
                                Rectangle()
                                    .fill(Color.primary.opacity(0.10))
                                    .frame(width: 1, height: 3)
                                    .offset(x: tick.element, y: rulerHeight - 4)
                            }
                            ForEach(Array(majorTicks.enumerated()), id: \.offset) { tick in
                                Rectangle()
                                    .fill(Color.primary.opacity(0.18))
                                    .frame(width: 1, height: 6)
                                    .offset(x: tick.element.x, y: rulerHeight - 7)
                            }
                            ForEach(Array(labeledMajorTicks.enumerated()), id: \.offset) { tick in
                                Text(rulerLabel(for: tick.element.seconds, majorStep: majorStep))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.primary.opacity(0.55))
                                    .offset(x: tick.element.x + 2, y: 0)
                            }
                        }
                    }
                    .allowsHitTesting(false)

                if hasSelection {
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    systemAccent.opacity(0.36),
                                    systemAccent.opacity(0.42),
                                    systemAccent.opacity(0.36)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: drawSelectionWidth, height: timelineHeight)
                        .offset(x: drawSelectionStartX, y: timelineVerticalOffset)
                        .overlay(
                            ZStack {
                                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                    .stroke(systemAccent.opacity(selectionOutlineOpacity), lineWidth: selectionOutlineWidth)
                                // Subtle inner shadow for slight depth without heavy contrast.
                                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                    .stroke(Color.black.opacity(0.14), lineWidth: 1.0)
                                    .blur(radius: 0.7)
                                    .mask(
                                        RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [Color.black.opacity(0.75), Color.clear],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                    )
                            }
                                .frame(width: drawSelectionWidth, height: timelineHeight)
                                .offset(x: drawSelectionStartX, y: timelineVerticalOffset)
                                .allowsHitTesting(false)
                        )

                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .fill(Color.white.opacity(selectionFlashOpacity))
                        .frame(width: drawSelectionWidth, height: timelineHeight)
                        .offset(x: drawSelectionStartX, y: timelineVerticalOffset)
                        .allowsHitTesting(false)
                }

                if startEdgeVisible {
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    systemAccent.opacity(startEdgeGlowOpacity),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: edgeGlowWidth, height: timelineHeight)
                        .offset(x: startX, y: timelineVerticalOffset)
                        .animation(.easeOut(duration: 0.16), value: isStartEdgeActive)
                        .allowsHitTesting(false)
                }

                if endEdgeVisible {
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    systemAccent.opacity(endEdgeGlowOpacity)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: edgeGlowWidth, height: timelineHeight)
                        .offset(x: max(startX, endX - edgeGlowWidth), y: timelineVerticalOffset)
                        .animation(.easeOut(duration: 0.16), value: isEndEdgeActive)
                        .allowsHitTesting(false)
                }

                if startEdgeVisible {
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    systemAccent.opacity(startBoundaryPulseOpacity),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: edgeGlowWidth, height: timelineHeight)
                        .offset(x: startX, y: timelineVerticalOffset)
                        .animation(.easeOut(duration: 0.16), value: highlightedClipBoundary)
                        .allowsHitTesting(false)
                }

                if endEdgeVisible {
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    systemAccent.opacity(endBoundaryPulseOpacity)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: edgeGlowWidth, height: timelineHeight)
                        .offset(x: max(startX, endX - edgeGlowWidth), y: timelineVerticalOffset)
                        .animation(.easeOut(duration: 0.16), value: highlightedClipBoundary)
                        .allowsHitTesting(false)
                }

                WaveformRasterLayerView(
                    player: player,
                    sourceSessionID: sourceSessionID,
                    samples: samples,
                    zoomLevel: zoomLevel,
                    renderBuckets: renderBuckets,
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
                    onMarkerSeek: { seconds in
                        onSeek(seconds, true)
                    },
                    onInteractiveSeek: onSeek,
                    onPlayheadDragStateChanged: onPlayheadDragStateChanged,
                    onPlayheadDragEdgePan: onPlayheadDragEdgePan
                )
                .frame(maxWidth: .infinity, minHeight: timelineHeight, maxHeight: timelineHeight, alignment: .center)
                .offset(y: timelineVerticalOffset)

                if startEdgeVisible {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: edgeHitWidth, height: timelineHeight)
                        .contentShape(Rectangle())
                        .offset(x: startX - (edgeHitWidth / 2), y: timelineVerticalOffset)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("waveformTimeline"))
                                .onChanged { value in
                                    if startEdgeDragAnchor == nil {
                                        startEdgeDragAnchor = startSeconds
                                    }
                                    isStartEdgeDragging = true
                                    isEndEdgeHovered = false
                                    NSCursor.closedHand.set()
                                    let anchor = startEdgeDragAnchor ?? startSeconds
                                    let deltaSeconds = Double(value.translation.width / max(width, 1)) * visibleDuration
                                    let newValue = min(max(0, anchor + deltaSeconds), endSeconds)
                                    onSetStart(newValue)
                                }
                                .onEnded { _ in
                                    startEdgeDragAnchor = nil
                                    isStartEdgeDragging = false
                                    if isStartEdgeHovered || isEndEdgeHovered {
                                        NSCursor.resizeLeftRight.set()
                                    } else {
                                        NSCursor.arrow.set()
                                    }
                                }
                        )
                }

                if endEdgeVisible {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: edgeHitWidth, height: timelineHeight)
                        .contentShape(Rectangle())
                        .offset(x: endX - (edgeHitWidth / 2), y: timelineVerticalOffset)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("waveformTimeline"))
                                .onChanged { value in
                                    if endEdgeDragAnchor == nil {
                                        endEdgeDragAnchor = endSeconds
                                    }
                                    isEndEdgeDragging = true
                                    isStartEdgeHovered = false
                                    NSCursor.closedHand.set()
                                    let anchor = endEdgeDragAnchor ?? endSeconds
                                    let deltaSeconds = Double(value.translation.width / max(width, 1)) * visibleDuration
                                    let newValue = max(min(totalDurationSeconds, anchor + deltaSeconds), startSeconds)
                                    onSetEnd(newValue)
                                }
                                .onEnded { _ in
                                    endEdgeDragAnchor = nil
                                    isEndEdgeDragging = false
                                    if isStartEdgeHovered || isEndEdgeHovered {
                                        NSCursor.resizeLeftRight.set()
                                    } else {
                                        NSCursor.arrow.set()
                                    }
                                }
                        )
                }

                if hasSelection {
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .stroke(Color.white.opacity(0.95), lineWidth: 2.0)
                        .frame(width: drawSelectionWidth)
                        .frame(height: max(1, timelineHeight - 8))
                        .offset(x: drawSelectionStartX, y: timelineVerticalOffset + 4)
                        .shadow(color: Color.accentColor.opacity(selectionFlashGlowOpacity), radius: 14)
                        .opacity(selectionFlashGlowOpacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .clipped()
            .coordinateSpace(name: "waveformTimeline")
            .overlay(
                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    .stroke(isHovered ? Color.accentColor.opacity(0.28) : Color.gray.opacity(0.16), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                onHoverChanged(hovering)
                if !hovering && !isStartEdgeDragging && !isEndEdgeDragging {
                    isStartEdgeHovered = false
                    isEndEdgeHovered = false
                    isResizeCursorActive = false
                    NSCursor.arrow.set()
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard !isStartEdgeDragging && !isEndEdgeDragging else { return }
                switch phase {
                case .active(let point):
                    let x = point.x
                    let pointerTime = timeValue(
                        for: x,
                        width: width,
                        windowStart: visibleStartSeconds,
                        windowEnd: visibleEndSeconds
                    )
                    onPointerTimeChanged(pointerTime)
                    let startDistance = abs(x - startX)
                    let endDistance = abs(x - endX)
                    let isNearStart = startDistance <= edgeHoverProximity
                    let isNearEnd = endDistance <= edgeHoverProximity
                    var nextStartEdgeHovered = false
                    var nextEndEdgeHovered = false

                    if isNearStart && isNearEnd {
                        if startDistance <= endDistance {
                            nextStartEdgeHovered = true
                        } else {
                            nextEndEdgeHovered = true
                        }
                    } else if isNearStart {
                        nextStartEdgeHovered = true
                    } else if isNearEnd {
                        nextEndEdgeHovered = true
                    }

                    if nextStartEdgeHovered != isStartEdgeHovered {
                        isStartEdgeHovered = nextStartEdgeHovered
                    }
                    if nextEndEdgeHovered != isEndEdgeHovered {
                        isEndEdgeHovered = nextEndEdgeHovered
                    }

                    let shouldUseResizeCursor = nextStartEdgeHovered || nextEndEdgeHovered
                    if shouldUseResizeCursor && !isResizeCursorActive {
                        isResizeCursorActive = true
                        NSCursor.resizeLeftRight.set()
                    } else if !shouldUseResizeCursor && isResizeCursorActive {
                        isResizeCursorActive = false
                        NSCursor.arrow.set()
                    }
                case .ended:
                    onPointerTimeChanged(nil)
                    isStartEdgeHovered = false
                    isEndEdgeHovered = false
                    isResizeCursorActive = false
                    if !isHovered {
                        NSCursor.arrow.set()
                    }
                }
            }
            .task(id: quickExportFlashToken) {
                guard quickExportFlashToken > 0 else { return }
                withAnimation(.easeOut(duration: 0.14)) {
                    selectionFlashOpacity = 0.52
                    selectionFlashGlowOpacity = 1.0
                }
                try? await Task.sleep(nanoseconds: 260_000_000)
                withAnimation(.easeOut(duration: 0.34)) {
                    selectionFlashOpacity = 0
                    selectionFlashGlowOpacity = 0
                }
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
        }
    }
}
