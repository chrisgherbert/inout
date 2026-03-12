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

private final class WaveformRasterHostView: NSView {
    struct MarkerHotspot {
        let id: UUID
        let seconds: Double
        let x: CGFloat
    }

    let waveformClipLayer = CALayer()
    let waveformLayer = CALayer()
    let markerContainerLayer = CALayer()
    let playheadLayer = CALayer()
    weak var player: AVPlayer?
    var totalDurationSeconds: Double = 0
    var visibleStartSeconds: Double = 0
    var visibleEndSeconds: Double = 1
    var modelPlayheadSeconds: Double = 0
    var playheadDisplayWidth: CGFloat = 2
    private var livePlaybackTimer: Timer?
    var onMarkerSeek: ((Double) -> Void)?
    var onInteractiveSeek: ((Double, Bool) -> Void)?
    var onPlayheadDragStateChanged: ((Bool) -> Void)?
    var onPlayheadDragEdgePan: ((CGFloat, CGFloat) -> Void)?
    var markerHotspots: [MarkerHotspot] = []
    var markerLayersByID: [UUID: CALayer] = [:]
    private var trackingAreaRef: NSTrackingArea?
    private var markerCursorActive = false
    private let markerHitTolerance: CGFloat = 12
    private var isDraggingPlayhead = false
    var dragPlayheadSeconds: Double?
    private var lastDragCommitTimestamp: CFTimeInterval = 0
    private var hoveredMarkerID: UUID? {
        didSet {
            applyMarkerHoverState(animated: true)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        waveformClipLayer.masksToBounds = true
        waveformClipLayer.cornerCurve = .continuous
        waveformClipLayer.cornerRadius = UIRadius.small
        waveformLayer.contentsGravity = .resize
        waveformLayer.magnificationFilter = .linear
        waveformLayer.minificationFilter = .linear
        waveformLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        waveformLayer.actions = [
            "contents": NSNull(),
            "contentsRect": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        markerContainerLayer.actions = [
            "sublayers": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        markerContainerLayer.masksToBounds = false
        markerContainerLayer.isGeometryFlipped = true
        playheadLayer.backgroundColor = NSColor.systemRed.cgColor
        playheadLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "opacity": NSNull(),
            "shadowOpacity": NSNull(),
            "shadowRadius": NSNull()
        ]
        waveformClipLayer.addSublayer(waveformLayer)
        layer?.addSublayer(waveformClipLayer)
        layer?.addSublayer(markerContainerLayer)
        layer?.addSublayer(playheadLayer)
    }

    deinit {
        stopLivePlaybackTimer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .inVisibleRect,
            .mouseMoved,
            .mouseEnteredAndExited
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    private func markerNear(point: NSPoint) -> MarkerHotspot? {
        // Shared hover/click hit test so both behaviors match exactly.
        markerHotspots.first(where: { abs($0.x - point.x) <= markerHitTolerance })
    }

    private var visibleDuration: Double {
        max(0.0001, visibleEndSeconds - visibleStartSeconds)
    }

    private func timeValue(forX x: CGFloat) -> Double {
        guard bounds.width > 0 else { return modelPlayheadSeconds }
        let ratio = min(max(0, x / bounds.width), 1.0)
        return min(totalDurationSeconds, max(0, visibleStartSeconds + (Double(ratio) * visibleDuration)))
    }

    private func snappedPlayheadFrame(for seconds: Double) -> CGRect {
        let local = (seconds - visibleStartSeconds) / visibleDuration
        let x = CGFloat(local) * bounds.width
        let snappedX = x.rounded()
        return CGRect(
            x: snappedX - (playheadDisplayWidth / 2.0),
            y: -4,
            width: playheadDisplayWidth,
            height: bounds.height + 8
        )
    }

    private func applyDisplayedPlayhead(_ seconds: Double) {
        let targetFrame = snappedPlayheadFrame(for: seconds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadLayer.frame = targetFrame
        let visible = targetFrame.midX >= -6 && targetFrame.midX <= (bounds.width + 6)
        playheadLayer.opacity = visible ? 1.0 : 0.0
        CATransaction.commit()
    }

    private func updateInteractiveDrag(at point: NSPoint, forceCommit: Bool) {
        let target = timeValue(forX: point.x)
        dragPlayheadSeconds = target
        applyDisplayedPlayhead(target)
        onPlayheadDragEdgePan?(point.x, bounds.width)

        let now = CACurrentMediaTime()
        // Keep the visible line immediate, but reduce actual seek pressure while dragging.
        // Lower seek cadence generally feels smoother than trying to seek on every drag event.
        let commitInterval = 1.0 / 24.0
        guard forceCommit || (now - lastDragCommitTimestamp) >= commitInterval else { return }
        lastDragCommitTimestamp = now
        onInteractiveSeek?(target, forceCommit)
    }

    func applyMarkerHoverState(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        for (id, layer) in markerLayersByID {
            let isHighlighted = (layer.value(forKey: "isHighlighted") as? Bool) ?? false
            let isHovered = id == hoveredMarkerID
            let targetShadowOpacity: Float = {
                if isHighlighted && isHovered { return 0.86 }
                if isHighlighted { return 0.6 }
                if isHovered { return 0.38 }
                return 0.0
            }()
            let targetShadowRadius: CGFloat = {
                if isHighlighted && isHovered { return 6.2 }
                if isHighlighted { return 4.0 }
                if isHovered { return 3.0 }
                return 0.0
            }()
            let targetScale: CGFloat = {
                if isHighlighted && isHovered { return 1.12 }
                if isHighlighted { return 1.0 }
                if isHovered { return 1.08 }
                return 1.0
            }()

            if animated {
                let shadowAnim = CABasicAnimation(keyPath: "shadowOpacity")
                shadowAnim.fromValue = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
                shadowAnim.toValue = targetShadowOpacity
                shadowAnim.duration = 0.12
                shadowAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                shadowAnim.isRemovedOnCompletion = true
                layer.add(shadowAnim, forKey: "hoverShadowOpacity")

                let radiusAnim = CABasicAnimation(keyPath: "shadowRadius")
                radiusAnim.fromValue = layer.presentation()?.shadowRadius ?? layer.shadowRadius
                radiusAnim.toValue = targetShadowRadius
                radiusAnim.duration = 0.12
                radiusAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                radiusAnim.isRemovedOnCompletion = true
                layer.add(radiusAnim, forKey: "hoverShadowRadius")

                let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
                scaleAnim.fromValue = (layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1.0
                scaleAnim.toValue = targetScale
                scaleAnim.duration = 0.12
                scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scaleAnim.isRemovedOnCompletion = true
                layer.add(scaleAnim, forKey: "hoverScale")
            }

            layer.shadowOpacity = targetShadowOpacity
            layer.shadowRadius = targetShadowRadius
            layer.transform = CATransform3DMakeScale(targetScale, targetScale, 1)
        }
        CATransaction.commit()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let marker = markerNear(point: point) {
            hoveredMarkerID = marker.id
            if !markerCursorActive {
                NSCursor.pointingHand.set()
                markerCursorActive = true
            }
        } else if markerCursorActive {
            hoveredMarkerID = nil
            NSCursor.arrow.set()
            markerCursorActive = false
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredMarkerID = nil
        if markerCursorActive {
            NSCursor.arrow.set()
            markerCursorActive = false
        }
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isDraggingPlayhead = true
        lastDragCommitTimestamp = 0
        onPlayheadDragStateChanged?(true)

        if let marker = markerNear(point: point) {
            dragPlayheadSeconds = marker.seconds
            applyDisplayedPlayhead(marker.seconds)
            onInteractiveSeek?(marker.seconds, true)
            return
        }

        updateInteractiveDrag(at: point, forceCommit: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingPlayhead else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        updateInteractiveDrag(at: point, forceCommit: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingPlayhead else {
            super.mouseUp(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        updateInteractiveDrag(at: point, forceCommit: true)
        isDraggingPlayhead = false
        dragPlayheadSeconds = nil
        onPlayheadDragStateChanged?(false)
    }

    override func layout() {
        super.layout()
        waveformClipLayer.frame = bounds
        waveformLayer.frame = waveformClipLayer.bounds
        markerContainerLayer.frame = bounds
    }

    private func startLivePlaybackTimerIfNeeded() {
        guard livePlaybackTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickLivePlayhead()
        }
        livePlaybackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopLivePlaybackTimer() {
        livePlaybackTimer?.invalidate()
        livePlaybackTimer = nil
    }

    func updateLivePlaybackTimerState() {
        guard let player else {
            stopLivePlaybackTimer()
            return
        }
        if player.rate != 0 {
            startLivePlaybackTimerIfNeeded()
        } else {
            stopLivePlaybackTimer()
        }
    }

    private func tickLivePlayhead() {
        guard !isDraggingPlayhead, let player, player.rate != 0 else {
            stopLivePlaybackTimer()
            return
        }
        let current = CMTimeGetSeconds(player.currentTime())
        guard current.isFinite else { return }
        applyDisplayedPlayhead(current)
    }
}

private final class WaveformRasterCoordinator {
    private var zoomRenderBuckets: [Double] = [1, 2, 4, 8, 16, 32, 64, 96, 128, 192, 256]
    private(set) var cachedSessionID: UUID?
    private(set) var cachedSamples: [Double] = []
    private(set) var cachedBucketImages: [Double: CGImage] = [:]
    private(set) var cachedIsDarkAppearance = false
    var lastAppliedContentsRect: CGRect = .null
    var lastContentsRectUpdateTime: CFTimeInterval = 0
    var lastAppliedBounds: CGRect = .zero
    var lastAppliedZoomBucket: Double = -1
    var lastPlayheadJumpAnimationToken: Int = -1
    var lastPlayheadCaptureFlashing: Bool = false
    var lastHighlightedMarkerID: UUID?
    var lastMarkerLayoutSignature: Int?

    func setZoomRenderBuckets(_ buckets: [Double]) {
        let normalized = Array(Set(buckets.map { max(1, $0) })).sorted()
        guard !normalized.isEmpty, normalized != zoomRenderBuckets else { return }
        zoomRenderBuckets = normalized
        let keep = Set(zoomRenderBuckets)
        cachedBucketImages = cachedBucketImages.filter { keep.contains($0.key) }
        lastAppliedZoomBucket = -1
    }

    @discardableResult
    func rebuildImageIfNeeded(sessionID: UUID, samples: [Double], isDarkAppearance: Bool) -> Bool {
        let needsRebuild =
            cachedBucketImages.isEmpty ||
            cachedSessionID != sessionID ||
            cachedSamples.count != samples.count ||
            cachedIsDarkAppearance != isDarkAppearance

        guard needsRebuild else { return false }

        cachedSessionID = sessionID
        cachedSamples = samples
        cachedIsDarkAppearance = isDarkAppearance
        cachedBucketImages = [:]
        lastAppliedContentsRect = .null
        lastContentsRectUpdateTime = 0
        lastAppliedBounds = .zero
        lastAppliedZoomBucket = -1
        lastMarkerLayoutSignature = nil
        return true
    }

    func image(for zoomBucket: Double) -> CGImage? {
        if let cached = cachedBucketImages[zoomBucket] {
            return cached
        }
        guard !cachedSamples.isEmpty else { return nil }
        let width = Int(min(98_304, max(4_096, (1_024.0 * zoomBucket).rounded())))
        let peaks = makePeaks(samples: cachedSamples, targetWidth: width)
        guard let image = makeWaveformImage(
            peaks: peaks,
            height: 96,
            isDarkAppearance: cachedIsDarkAppearance,
            useSkippedColumns: zoomBucket >= 32,
            zoomBucket: zoomBucket
        ) else {
            return nil
        }
        cachedBucketImages[zoomBucket] = image
        return image
    }

    private func makePeaks(samples: [Double], targetWidth: Int) -> [Double] {
        let width = max(1, targetWidth)
        let n = max(samples.count - 1, 1)
        var peaks = Array(repeating: 0.0, count: width)
        for x in 0..<width {
            let startRatio = Double(x) / Double(width)
            let endRatio = Double(x + 1) / Double(width)
            var startIndex = Int((startRatio * Double(n)).rounded(.down))
            var endIndex = Int((endRatio * Double(n)).rounded(.up))
            startIndex = min(max(0, startIndex), n)
            endIndex = min(max(startIndex, endIndex), n)
            var peak = 0.0
            var i = startIndex
            while i <= endIndex {
                peak = max(peak, samples[i])
                i += 1
            }
            peaks[x] = peak
        }
        return peaks
    }

    private func makeWaveformImage(
        peaks: [Double],
        height: Int,
        isDarkAppearance: Bool,
        useSkippedColumns: Bool,
        zoomBucket: Double
    ) -> CGImage? {
        guard !peaks.isEmpty else { return nil }

        let width = peaks.count
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let barAlpha: CGFloat = {
            if zoomBucket >= 32 {
                return isDarkAppearance ? 0.64 : 0.58
            }
            return isDarkAppearance ? 0.43 : 0.37
        }()
        let barColor: NSColor = {
            if isDarkAppearance {
                return NSColor(calibratedWhite: 1.0, alpha: barAlpha)
            }
            return NSColor.labelColor.withAlphaComponent(barAlpha)
        }()
        context.setFillColor(barColor.cgColor)

        let baselineY = 2.0
        let maxBarHeight = max(1.0, CGFloat(height) - 4.0)

        let minNormalizedBar: Double = {
            if zoomBucket >= 32 { return 0.02 }
            return 0.01
        }()

        for x in 0..<width {
            if useSkippedColumns && x % 2 != 0 {
                continue
            }
            let peak = peaks[x]
            let normalized = max(minNormalizedBar, min(1.0, peak))
            let amp = CGFloat(normalized) * maxBarHeight
            let rect = CGRect(x: CGFloat(x), y: baselineY, width: 1, height: amp)
            context.fill(rect)
        }

        return context.makeImage()
    }

    func bestZoomRenderBucket(for zoomLevel: Double) -> Double {
        for bucket in zoomRenderBuckets where bucket >= zoomLevel {
            return bucket
        }
        return zoomRenderBuckets.last ?? max(1, zoomLevel)
    }
}

private struct WaveformRasterLayerView: NSViewRepresentable, Equatable {
    let player: AVPlayer
    let sourceSessionID: UUID
    let samples: [Double]
    let zoomLevel: Double
    let renderBuckets: [Double]
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let isDarkAppearance: Bool
    let playheadSeconds: Double
    let playheadJumpFromSeconds: Double
    let playheadJumpAnimationToken: Int
    let isPlayheadCaptureFlashing: Bool
    let captureMarkers: [CaptureTimelineMarker]
    let highlightedMarkerID: UUID?
    let onMarkerSeek: (Double) -> Void
    let onInteractiveSeek: (Double, Bool) -> Void
    let onPlayheadDragStateChanged: (Bool) -> Void
    let onPlayheadDragEdgePan: (CGFloat, CGFloat) -> Void

    static func == (lhs: WaveformRasterLayerView, rhs: WaveformRasterLayerView) -> Bool {
        lhs.sourceSessionID == rhs.sourceSessionID &&
        ObjectIdentifier(lhs.player) == ObjectIdentifier(rhs.player) &&
        lhs.samples.count == rhs.samples.count &&
        abs(lhs.zoomLevel - rhs.zoomLevel) < 0.0001 &&
        lhs.renderBuckets == rhs.renderBuckets &&
        abs(lhs.totalDurationSeconds - rhs.totalDurationSeconds) < 0.0001 &&
        abs(lhs.visibleStartSeconds - rhs.visibleStartSeconds) < 0.0001 &&
        abs(lhs.visibleEndSeconds - rhs.visibleEndSeconds) < 0.0001 &&
        lhs.isDarkAppearance == rhs.isDarkAppearance &&
        abs(lhs.playheadSeconds - rhs.playheadSeconds) < 0.0001 &&
        abs(lhs.playheadJumpFromSeconds - rhs.playheadJumpFromSeconds) < 0.0001 &&
        lhs.playheadJumpAnimationToken == rhs.playheadJumpAnimationToken &&
        lhs.isPlayheadCaptureFlashing == rhs.isPlayheadCaptureFlashing &&
        lhs.captureMarkers == rhs.captureMarkers &&
        lhs.highlightedMarkerID == rhs.highlightedMarkerID
    }

    func makeCoordinator() -> WaveformRasterCoordinator {
        WaveformRasterCoordinator()
    }

    func makeNSView(context: Context) -> WaveformRasterHostView {
        let view = WaveformRasterHostView()
        view.onMarkerSeek = onMarkerSeek
        view.onInteractiveSeek = onInteractiveSeek
        view.onPlayheadDragStateChanged = onPlayheadDragStateChanged
        view.onPlayheadDragEdgePan = onPlayheadDragEdgePan
        return view
    }

    func updateNSView(_ nsView: WaveformRasterHostView, context: Context) {
        nsView.onMarkerSeek = onMarkerSeek
        nsView.onInteractiveSeek = onInteractiveSeek
        nsView.onPlayheadDragStateChanged = onPlayheadDragStateChanged
        nsView.onPlayheadDragEdgePan = onPlayheadDragEdgePan
        nsView.player = player
        nsView.modelPlayheadSeconds = playheadSeconds
        context.coordinator.setZoomRenderBuckets(renderBuckets)

        let didRebuildImage = context.coordinator.rebuildImageIfNeeded(
            sessionID: sourceSessionID,
            samples: samples,
            isDarkAppearance: isDarkAppearance
        )

        guard !context.coordinator.cachedSamples.isEmpty else {
            nsView.waveformLayer.contents = nil
            return
        }

        let duration = max(0.0001, totalDurationSeconds)
        let rawStartNorm = min(max(0, visibleStartSeconds / duration), 1.0)
        let rawEndNorm = min(max(rawStartNorm + 0.000001, visibleEndSeconds / duration), 1.0)
        let zoomBucket = context.coordinator.bestZoomRenderBucket(for: zoomLevel)
        let image = context.coordinator.image(for: zoomBucket)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if let image,
           (didRebuildImage || context.coordinator.lastAppliedZoomBucket != zoomBucket || nsView.waveformLayer.contents == nil) {
            nsView.waveformLayer.contents = image
            context.coordinator.lastAppliedZoomBucket = zoomBucket
            nsView.waveformLayer.magnificationFilter = zoomBucket >= 32 ? .nearest : .linear
            nsView.waveformLayer.minificationFilter = .linear
        }

        guard let activeImage = image else {
            nsView.waveformLayer.contents = nil
            CATransaction.commit()
            return
        }
        _ = activeImage
        let newContentsRect = CGRect(
            x: rawStartNorm,
            y: 0,
            width: max(0.000001, rawEndNorm - rawStartNorm),
            height: 1
        )

        if !newContentsRect.equalTo(context.coordinator.lastAppliedContentsRect) {
            let oldRect = context.coordinator.lastAppliedContentsRect
            let now = CACurrentMediaTime()
            let lastUpdate = context.coordinator.lastContentsRectUpdateTime
            // If updates are arriving rapidly, treat as continuous interaction
            // (drag/scroll) and avoid heavy catch-up animations.
            let isContinuousViewportInteraction = lastUpdate > 0 && (now - lastUpdate) < 0.08
            if oldRect != .null {
                let deltaX = abs(newContentsRect.origin.x - oldRect.origin.x)
                let deltaWidth = abs(newContentsRect.width - oldRect.width)
                // Smooth both viewport pans and zoom resizes for discrete jumps.
                if (deltaX > 0.01 || deltaWidth > 0.01) && !isContinuousViewportInteraction {
                    let anim = CABasicAnimation(keyPath: "contentsRect")
                    anim.fromValue = oldRect
                    anim.toValue = newContentsRect
                    anim.duration = 0.20
                    anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    anim.isRemovedOnCompletion = true
                    nsView.waveformLayer.add(anim, forKey: "viewportRecenter")
                }
            }
            nsView.waveformLayer.contentsRect = newContentsRect
            context.coordinator.lastAppliedContentsRect = newContentsRect

            if oldRect != .null {
                let deltaX = abs(newContentsRect.origin.x - oldRect.origin.x)
                if deltaX > 0.01 && !isContinuousViewportInteraction {
                    let normWidth = max(0.000001, newContentsRect.width)
                    let markerScrollShiftX = CGFloat((newContentsRect.origin.x - oldRect.origin.x) / normWidth) * nsView.bounds.width
                    if markerScrollShiftX != 0 {
                        let markerPan = CABasicAnimation(keyPath: "sublayerTransform.translation.x")
                        markerPan.fromValue = markerScrollShiftX
                        markerPan.toValue = 0
                        markerPan.duration = 0.22
                        markerPan.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        markerPan.isRemovedOnCompletion = true
                        nsView.markerContainerLayer.add(markerPan, forKey: "viewportRecenterMarkers")
                    }
                }
            }
            context.coordinator.lastContentsRectUpdateTime = now
        }

        if !nsView.bounds.equalTo(context.coordinator.lastAppliedBounds) {
            nsView.waveformLayer.frame = nsView.bounds
            context.coordinator.lastAppliedBounds = nsView.bounds
        }

        let visibleDuration = max(0.0001, visibleEndSeconds - visibleStartSeconds)
        let width = nsView.bounds.width
        func xPosition(for seconds: Double) -> CGFloat {
            let local = seconds - visibleStartSeconds
            return CGFloat(local / visibleDuration) * width
        }
        let backingScale = nsView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let pixel = CGFloat(1.0 / backingScale)
        func snapToPixel(_ value: CGFloat) -> CGFloat {
            (value / pixel).rounded() * pixel
        }

        let displayedPlayheadSeconds = nsView.dragPlayheadSeconds ?? playheadSeconds
        let playheadX = snapToPixel(xPosition(for: displayedPlayheadSeconds))
        let playheadWidth: CGFloat = isPlayheadCaptureFlashing ? 3.6 : 2.0
        nsView.totalDurationSeconds = totalDurationSeconds
        nsView.visibleStartSeconds = visibleStartSeconds
        nsView.visibleEndSeconds = visibleEndSeconds
        nsView.playheadDisplayWidth = playheadWidth
        nsView.updateLivePlaybackTimerState()
        let targetPlayheadFrame = CGRect(
            x: playheadX - (playheadWidth / 2.0),
            y: -4,
            width: playheadWidth,
            height: nsView.bounds.height + 8
        )
        if playheadJumpAnimationToken != context.coordinator.lastPlayheadJumpAnimationToken {
            let fromX = xPosition(for: playheadJumpFromSeconds)
            let toX = targetPlayheadFrame.midX
            if abs(toX - fromX) > 0.5 {
                let move = CABasicAnimation(keyPath: "position.x")
                move.fromValue = fromX
                move.toValue = toX
                move.duration = 0.22
                move.timingFunction = CAMediaTimingFunction(name: .easeOut)
                move.isRemovedOnCompletion = true
                nsView.playheadLayer.add(move, forKey: "playheadJump")
            }
            context.coordinator.lastPlayheadJumpAnimationToken = playheadJumpAnimationToken
        }

        nsView.playheadLayer.frame = targetPlayheadFrame
        let playheadVisible = playheadX >= -6 && playheadX <= (width + 6)
        nsView.playheadLayer.opacity = playheadVisible ? 1.0 : 0.0
        nsView.playheadLayer.shadowColor = NSColor.systemRed.cgColor
        let targetShadowOpacity: Float = isPlayheadCaptureFlashing ? 0.9 : 0.0
        let targetShadowRadius: CGFloat = isPlayheadCaptureFlashing ? 6 : 0
        if isPlayheadCaptureFlashing != context.coordinator.lastPlayheadCaptureFlashing {
            let shadowOpacityAnim = CABasicAnimation(keyPath: "shadowOpacity")
            shadowOpacityAnim.fromValue = nsView.playheadLayer.presentation()?.shadowOpacity ?? nsView.playheadLayer.shadowOpacity
            shadowOpacityAnim.toValue = targetShadowOpacity
            shadowOpacityAnim.duration = isPlayheadCaptureFlashing ? 0.08 : 0.2
            shadowOpacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shadowOpacityAnim.isRemovedOnCompletion = true
            nsView.playheadLayer.add(shadowOpacityAnim, forKey: "playheadShadowOpacity")

            let shadowRadiusAnim = CABasicAnimation(keyPath: "shadowRadius")
            shadowRadiusAnim.fromValue = nsView.playheadLayer.presentation()?.shadowRadius ?? nsView.playheadLayer.shadowRadius
            shadowRadiusAnim.toValue = targetShadowRadius
            shadowRadiusAnim.duration = shadowOpacityAnim.duration
            shadowRadiusAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shadowRadiusAnim.isRemovedOnCompletion = true
            nsView.playheadLayer.add(shadowRadiusAnim, forKey: "playheadShadowRadius")
        }
        nsView.playheadLayer.shadowOpacity = targetShadowOpacity
        nsView.playheadLayer.shadowRadius = targetShadowRadius
        context.coordinator.lastPlayheadCaptureFlashing = isPlayheadCaptureFlashing

        let markerContainer = nsView.markerContainerLayer
        let visibleMarkers = captureMarkers.enumerated().filter { _, marker in
            marker.seconds >= visibleStartSeconds && marker.seconds <= visibleEndSeconds
        }
        var markerLayoutHasher = Hasher()
        markerLayoutHasher.combine(visibleMarkers.count)
        markerLayoutHasher.combine(highlightedMarkerID)
        markerLayoutHasher.combine(Int((nsView.bounds.width * backingScale).rounded()))
        markerLayoutHasher.combine(Int((nsView.bounds.height * backingScale).rounded()))
        for (_, marker) in visibleMarkers {
            markerLayoutHasher.combine(marker.id)
            markerLayoutHasher.combine(Int((snapToPixel(xPosition(for: marker.seconds)) * backingScale).rounded()))
        }
        let markerLayoutSignature = markerLayoutHasher.finalize()

        if context.coordinator.lastMarkerLayoutSignature != markerLayoutSignature {
            var markerHotspots: [WaveformRasterHostView.MarkerHotspot] = []
            var markerLayersByID: [UUID: CALayer] = [:]
            markerContainer.sublayers = visibleMarkers.map { _, marker in
                let markerX = snapToPixel(xPosition(for: marker.seconds))
                markerHotspots.append(.init(id: marker.id, seconds: marker.seconds, x: markerX))
                let isHighlighted = marker.id == highlightedMarkerID
                let pinColor = NSColor.systemOrange.withAlphaComponent(isHighlighted ? 1.0 : 0.9)

                let pin = CALayer()
                // Keep pinhead visually above timeline while leaving most of it inside hit-testable bounds.
                pin.frame = CGRect(x: markerX - (isHighlighted ? 4.5 : 4.0), y: -2, width: isHighlighted ? 9 : 8, height: nsView.bounds.height + 6)
                pin.setValue(isHighlighted, forKey: "isHighlighted")

                let head = CALayer()
                head.backgroundColor = pinColor.cgColor
                head.frame = CGRect(x: 0, y: 0, width: isHighlighted ? 9 : 8, height: isHighlighted ? 9 : 8)
                head.cornerRadius = head.bounds.width / 2
                pin.addSublayer(head)

                let stem = CALayer()
                stem.backgroundColor = NSColor.systemOrange.withAlphaComponent(isHighlighted ? 0.96 : 0.8).cgColor
                let stemWidth: CGFloat = isHighlighted ? 2.6 : 2.0
                stem.frame = CGRect(x: (head.bounds.width - stemWidth) / 2.0, y: head.frame.maxY, width: stemWidth, height: nsView.bounds.height + 4)
                pin.addSublayer(stem)

                pin.shadowColor = NSColor.systemOrange.cgColor
                pin.shadowOpacity = isHighlighted ? 0.6 : 0
                pin.shadowRadius = isHighlighted ? 4 : 0
                markerLayersByID[marker.id] = pin
                return pin
            }
            nsView.markerHotspots = markerHotspots
            nsView.markerLayersByID = markerLayersByID
            context.coordinator.lastMarkerLayoutSignature = markerLayoutSignature
        }
        nsView.applyMarkerHoverState(animated: false)

        if highlightedMarkerID != context.coordinator.lastHighlightedMarkerID,
           let highlightedMarkerID,
           let visibleIndex = visibleMarkers.firstIndex(where: { $0.element.id == highlightedMarkerID }),
           let markerLayers = markerContainer.sublayers,
           visibleIndex >= 0, visibleIndex < markerLayers.count {
            let pinLayer = markerLayers[visibleIndex]
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0.0
            glow.toValue = 0.6
            glow.duration = 0.16
            glow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            glow.isRemovedOnCompletion = true
            pinLayer.add(glow, forKey: "markerGlow")

            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1.0
            pulse.toValue = 1.09
            pulse.duration = 0.10
            pulse.autoreverses = true
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.isRemovedOnCompletion = true
            pinLayer.add(pulse, forKey: "markerPulse")
        }
        context.coordinator.lastHighlightedMarkerID = highlightedMarkerID

        CATransaction.commit()
    }
}

struct UnifiedClipTimelineSelector: View {
    @Binding var startSeconds: Double
    @Binding var playheadSeconds: Double
    @Binding var endSeconds: Double
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let captureMarkers: [CaptureTimelineMarker]
    let highlightedMarkerID: UUID?
    let onSeek: (Double) -> Void
    @State private var seekDragWindowStart: Double?
    @State private var seekDragWindowEnd: Double?
    @State private var isHovered = false
    @State private var isStartHandleHovered = false
    @State private var isEndHandleHovered = false
    @State private var startHandleDragAnchor: Double?
    @State private var endHandleDragAnchor: Double?

    private var visibleDuration: Double {
        max(0.0001, visibleEndSeconds - visibleStartSeconds)
    }

    private func xPosition(for value: Double, width: CGFloat) -> CGFloat {
        let local = value - visibleStartSeconds
        return CGFloat(min(max(0, local / visibleDuration), 1.0)) * width
    }

    private func timeValue(for x: CGFloat, width: CGFloat, windowStart: Double, windowEnd: Double) -> Double {
        guard width > 0 else { return 0 }
        let ratio = min(max(0, x / width), 1.0)
        let duration = max(0.0001, windowEnd - windowStart)
        return min(totalDurationSeconds, max(0, windowStart + (Double(ratio) * duration)))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let startX = xPosition(for: startSeconds, width: width)
            let playheadX = xPosition(for: playheadSeconds, width: width)
            let endX = xPosition(for: endSeconds, width: width)
            let handleSize: CGFloat = 16
            let handleOffsetY: CGFloat = 13

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    .fill(Color.black.opacity(isHovered ? 0.30 : 0.24))
                    .frame(height: 10)
                    .offset(y: 15)

                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.85),
                                Color.accentColor.opacity(0.95),
                                Color.blue.opacity(0.85)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, endX - startX), height: 10)
                    .offset(x: startX, y: 15)
                    .overlay(
                        RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                            .frame(width: max(2, endX - startX), height: 10)
                            .offset(x: startX, y: 15)
                    )

                ForEach(captureMarkers) { marker in
                    let markerX = xPosition(for: marker.seconds, width: width)
                    let isHighlighted = marker.id == highlightedMarkerID
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(isHighlighted ? Color.orange : Color.orange.opacity(0.74))
                        .frame(width: isHighlighted ? 5 : 3, height: isHighlighted ? 24 : 18)
                        .scaleEffect(isHighlighted ? 1.12 : 1.0, anchor: .center)
                        .shadow(
                            color: isHighlighted ? Color.orange.opacity(0.5) : Color.clear,
                            radius: isHighlighted ? 4 : 0
                        )
                        .offset(x: markerX - (isHighlighted ? 2.5 : 1.5), y: isHighlighted ? 8 : 11)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 2, height: 24)
                    .offset(x: playheadX - 1, y: 8)
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 16, height: 28)
                    .contentShape(Rectangle())
                    .offset(x: playheadX - 8, y: 6)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if seekDragWindowStart == nil || seekDragWindowEnd == nil {
                                    seekDragWindowStart = visibleStartSeconds
                                    seekDragWindowEnd = visibleEndSeconds
                                }
                                let windowStart = seekDragWindowStart ?? visibleStartSeconds
                                let windowEnd = seekDragWindowEnd ?? visibleEndSeconds
                                let newValue = timeValue(for: value.location.x, width: width, windowStart: windowStart, windowEnd: windowEnd)
                                onSeek(newValue)
                            }
                            .onEnded { _ in
                                seekDragWindowStart = nil
                                seekDragWindowEnd = nil
                            }
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: handleSize, height: handleSize)
                    .overlay(
                        Circle()
                            .stroke(Color.accentColor.opacity(0.95), lineWidth: 2)
                            .frame(width: handleSize, height: handleSize)
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(isStartHandleHovered ? 0.9 : 0), lineWidth: 1.5)
                            .scaleEffect(isStartHandleHovered ? 1.3 : 1.0)
                            .animation(.easeOut(duration: 0.12), value: isStartHandleHovered)
                    )
                    .shadow(color: Color.accentColor.opacity(isStartHandleHovered ? 0.35 : 0), radius: isStartHandleHovered ? 5 : 0)
                    .offset(x: startX - (handleSize / 2), y: handleOffsetY)
                    .allowsHitTesting(false)

                Circle()
                    .fill(Color.clear)
                    .frame(width: handleSize, height: handleSize)
                    .contentShape(Circle())
                    .offset(x: startX - (handleSize / 2), y: handleOffsetY)
                    .onHover { isOver in
                        isStartHandleHovered = isOver
                    }
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("clipTimelineTrack"))
                            .onChanged { value in
                                if startHandleDragAnchor == nil {
                                    startHandleDragAnchor = startSeconds
                                }
                                let anchor = startHandleDragAnchor ?? startSeconds
                                let deltaSeconds = Double(value.translation.width / max(width, 1)) * visibleDuration
                                let newValue = min(max(0, anchor + deltaSeconds), endSeconds)
                                startSeconds = newValue
                            }
                            .onEnded { _ in
                                startHandleDragAnchor = nil
                            }
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: handleSize, height: handleSize)
                    .overlay(
                        Circle()
                            .stroke(Color.accentColor.opacity(0.95), lineWidth: 2)
                            .frame(width: handleSize, height: handleSize)
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(isEndHandleHovered ? 0.9 : 0), lineWidth: 1.5)
                            .scaleEffect(isEndHandleHovered ? 1.3 : 1.0)
                            .animation(.easeOut(duration: 0.12), value: isEndHandleHovered)
                    )
                    .shadow(color: Color.accentColor.opacity(isEndHandleHovered ? 0.35 : 0), radius: isEndHandleHovered ? 5 : 0)
                    .offset(x: endX - (handleSize / 2), y: handleOffsetY)
                    .allowsHitTesting(false)

                Circle()
                    .fill(Color.clear)
                    .frame(width: handleSize, height: handleSize)
                    .contentShape(Circle())
                    .offset(x: endX - (handleSize / 2), y: handleOffsetY)
                    .onHover { isOver in
                        isEndHandleHovered = isOver
                    }
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("clipTimelineTrack"))
                            .onChanged { value in
                                if endHandleDragAnchor == nil {
                                    endHandleDragAnchor = endSeconds
                                }
                                let anchor = endHandleDragAnchor ?? endSeconds
                                let deltaSeconds = Double(value.translation.width / max(width, 1)) * visibleDuration
                                let newValue = max(min(totalDurationSeconds, anchor + deltaSeconds), startSeconds)
                                endSeconds = newValue
                            }
                            .onEnded { _ in
                                endHandleDragAnchor = nil
                            }
                    )
            }
            .coordinateSpace(name: "clipTimelineTrack")
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: highlightedMarkerID)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if seekDragWindowStart == nil || seekDragWindowEnd == nil {
                            seekDragWindowStart = visibleStartSeconds
                            seekDragWindowEnd = visibleEndSeconds
                        }
                        let windowStart = seekDragWindowStart ?? visibleStartSeconds
                        let windowEnd = seekDragWindowEnd ?? visibleEndSeconds
                        let newValue = timeValue(for: value.location.x, width: width, windowStart: windowStart, windowEnd: windowEnd)
                        onSeek(newValue)
                    }
                    .onEnded { _ in
                        seekDragWindowStart = nil
                        seekDragWindowEnd = nil
                    }
            , including: .gesture)
        }
    }
}

struct TimelineViewportScroller: View {
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let onViewportStartChanged: (Double) -> Void
    var body: some View {
        NativeTimelineScroller(
            totalDurationSeconds: totalDurationSeconds,
            visibleStartSeconds: visibleStartSeconds,
            visibleEndSeconds: visibleEndSeconds,
            onViewportStartChanged: onViewportStartChanged
        )
        .help("Use trackpad/mouse scrolling for native pan and momentum")
    }
}

private final class TimelineScrollerContentView: NSView {}

private final class TimelineScrollerCoordinator: NSObject {
    var suppressCallback = false
    var onViewportStartChanged: (Double) -> Void
    var maxViewportStartSeconds: Double = 0
    weak var clipView: NSClipView?
    weak var contentView: NSView?

    init(onViewportStartChanged: @escaping (Double) -> Void) {
        self.onViewportStartChanged = onViewportStartChanged
    }

    @objc func boundsChanged(_ notification: Notification) {
        guard !suppressCallback,
              let clipView,
              let contentView else { return }

        let contentWidth = max(1, contentView.frame.width)
        let visibleWidth = max(1, clipView.bounds.width)
        let maxOffset = max(0, contentWidth - visibleWidth)
        guard maxOffset > 0 else { return }

        let ratio = min(max(0, Double(clipView.bounds.origin.x / maxOffset)), 1.0)
        onViewportStartChanged(ratio * maxViewportStartSeconds)
    }
}

private struct NativeTimelineScroller: NSViewRepresentable {
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let onViewportStartChanged: (Double) -> Void

    func makeCoordinator() -> TimelineScrollerCoordinator {
        TimelineScrollerCoordinator(onViewportStartChanged: onViewportStartChanged)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.scrollerStyle = .legacy

        let content = TimelineScrollerContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.documentView = content

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(TimelineScrollerCoordinator.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )

        context.coordinator.clipView = clipView
        context.coordinator.contentView = content
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onViewportStartChanged = onViewportStartChanged
        guard let content = nsView.documentView else { return }

        let visibleDuration = max(0.0001, visibleEndSeconds - visibleStartSeconds)
        let totalDuration = max(0.0001, totalDurationSeconds)
        let viewportRatio = min(1.0, visibleDuration / totalDuration)
        let viewportWidth = max(1, nsView.contentSize.width)

        // Use proportional content width so native scroller knob maps 1:1 with viewport range.
        let contentWidth = max(viewportWidth, viewportWidth / max(viewportRatio, 0.0001))
        if abs(content.frame.width - contentWidth) > 0.5 {
            content.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 1)
        }

        let maxViewportStart = max(0.0, totalDuration - visibleDuration)
        context.coordinator.maxViewportStartSeconds = maxViewportStart
        let maxOffset = max(0.0, contentWidth - viewportWidth)
        let targetOffset: CGFloat
        if maxViewportStart > 0, maxOffset > 0 {
            let ratio = min(max(0, visibleStartSeconds / maxViewportStart), 1.0)
            targetOffset = CGFloat(ratio) * maxOffset
        } else {
            targetOffset = 0
        }

        if abs(nsView.contentView.bounds.origin.x - targetOffset) > 0.5 {
            context.coordinator.suppressCallback = true
            nsView.contentView.bounds.origin.x = targetOffset
            nsView.reflectScrolledClipView(nsView.contentView)
            context.coordinator.suppressCallback = false
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: TimelineScrollerCoordinator) {
        if let clipView = coordinator.clipView {
            NotificationCenter.default.removeObserver(
                coordinator,
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }
    }
}
