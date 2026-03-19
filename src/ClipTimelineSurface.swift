import AppKit
import AVFoundation
import CoreVideo
import Foundation
import SwiftUI

final class WaveformRasterHostView: NSView {
    struct MarkerHotspot {
        let id: UUID
        let seconds: Double
        let x: CGFloat
    }

    let surfaceLayer = CALayer()
    let backgroundLayer = CALayer()
    let rulerBaselineLayer = CALayer()
    let rulerTicksLayer = CAShapeLayer()
    let rulerLabelsLayer = CALayer()
    let selectionFillLayer = CALayer()
    let selectionFillMaskLayer = CAShapeLayer()
    let selectionOutlineLayer = CAShapeLayer()
    let selectionFlashLayer = CALayer()
    let selectionFlashMaskLayer = CAShapeLayer()
    let startEdgeGlowLayer = CAGradientLayer()
    let endEdgeGlowLayer = CAGradientLayer()
    let startBoundaryPulseLayer = CAGradientLayer()
    let endBoundaryPulseLayer = CAGradientLayer()
    let waveformClipLayer = CALayer()
    let waveformLayer = CALayer()
    let markerContainerLayer = CALayer()
    let playheadLayer = CALayer()
    weak var player: AVPlayer?
    var clipStartSeconds: Double = 0
    var clipEndSeconds: Double = 0
    var totalDurationSeconds: Double = 0
    var visibleStartSeconds: Double = 0
    var visibleEndSeconds: Double = 1
    var modelPlayheadSeconds: Double = 0
    var playheadDisplayWidth: CGFloat = 2
    var isDarkAppearance = false
    var highlightedClipBoundary: ClipBoundaryHighlight?
    private var livePlaybackDisplayLink: CVDisplayLink?
    private var hasPendingDisplayLinkTick = false
    private var playbackAnchorSeconds: Double = 0
    private var playbackAnchorHostTime: CFTimeInterval = 0
    private var playbackAnchorRate: Float = 0
    private var hasPlaybackAnchor = false
    private var lastDragSampleHostTime: CFTimeInterval = 0
    var onMarkerSeek: ((Double) -> Void)?
    var onInteractiveSeek: ((Double, Bool) -> Void)?
    var onPlayheadDragStateChanged: ((Bool) -> Void)?
    var onClipBoundaryDragStateChanged: ((Bool) -> Void)?
    var onPlayheadDragEdgePan: ((CGFloat, CGFloat) -> Void)?
    var onSetStart: ((Double) -> Void)?
    var onSetEnd: ((Double) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onPointerTimeChanged: ((Double?) -> Void)?
    var markerHotspots: [MarkerHotspot] = []
    var markerLayersByID: [UUID: CALayer] = [:]
    private var trackingAreaRef: NSTrackingArea?
    private var markerCursorActive = false
    private let markerHitTolerance: CGFloat = 12
    private var isDraggingPlayhead = false
    private var isDraggingStartEdge = false
    private var isDraggingEndEdge = false
    private var isPointerInside = false
    private var isStartEdgeHovered = false
    private var isEndEdgeHovered = false
    private var lastDecorationSignature: Int?
    var dragPlayheadSeconds: Double?
    private var lastDragCommitTimestamp: CFTimeInterval = 0
    private var hoveredMarkerID: UUID? {
        didSet {
            applyMarkerHoverState(animated: true)
        }
    }
    private var lastStartEdgeGlowOpacity: Float = 0
    private var lastEndEdgeGlowOpacity: Float = 0
    private var lastStartBoundaryPulseOpacity: Float = 0
    private var lastEndBoundaryPulseOpacity: Float = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        surfaceLayer.isGeometryFlipped = true
        surfaceLayer.masksToBounds = false
        layer?.addSublayer(surfaceLayer)
        backgroundLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "backgroundColor": NSNull()
        ]
        backgroundLayer.cornerCurve = .continuous
        backgroundLayer.cornerRadius = UIRadius.small
        surfaceLayer.addSublayer(backgroundLayer)
        rulerBaselineLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "backgroundColor": NSNull()
        ]
        surfaceLayer.addSublayer(rulerBaselineLayer)
        rulerTicksLayer.actions = [
            "path": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "strokeColor": NSNull()
        ]
        rulerTicksLayer.fillColor = nil
        rulerTicksLayer.lineCap = .square
        surfaceLayer.addSublayer(rulerTicksLayer)
        rulerLabelsLayer.actions = [
            "sublayers": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        rulerLabelsLayer.isGeometryFlipped = true
        surfaceLayer.addSublayer(rulerLabelsLayer)
        selectionFillLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "backgroundColor": NSNull(),
            "opacity": NSNull(),
            "cornerRadius": NSNull()
        ]
        selectionFillMaskLayer.actions = [
            "path": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        selectionFillLayer.mask = selectionFillMaskLayer
        surfaceLayer.addSublayer(selectionFillLayer)
        selectionOutlineLayer.actions = [
            "path": NSNull(),
            "strokeColor": NSNull(),
            "lineWidth": NSNull(),
            "opacity": NSNull()
        ]
        selectionOutlineLayer.fillColor = nil
        surfaceLayer.addSublayer(selectionOutlineLayer)
        selectionFlashLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "backgroundColor": NSNull(),
            "opacity": NSNull(),
            "cornerRadius": NSNull()
        ]
        selectionFlashMaskLayer.actions = [
            "path": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        selectionFlashLayer.mask = selectionFlashMaskLayer
        surfaceLayer.addSublayer(selectionFlashLayer)
        for edgeLayer in [startEdgeGlowLayer, endEdgeGlowLayer, startBoundaryPulseLayer, endBoundaryPulseLayer] {
            edgeLayer.actions = [
                "bounds": NSNull(),
                "position": NSNull(),
                "colors": NSNull(),
                "opacity": NSNull()
            ]
            edgeLayer.startPoint = CGPoint(x: 0, y: 0.5)
            edgeLayer.endPoint = CGPoint(x: 1, y: 0.5)
            surfaceLayer.addSublayer(edgeLayer)
        }
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
        surfaceLayer.addSublayer(waveformClipLayer)
        surfaceLayer.addSublayer(markerContainerLayer)
        surfaceLayer.addSublayer(playheadLayer)
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

    private var rulerHeight: CGFloat { 16 }
    private var rulerGap: CGFloat { 2 }
    private var markerTopGutter: CGFloat { 8 }
    private var markerBottomGutter: CGFloat { 8 }
    private var timelineVerticalOffset: CGFloat { rulerHeight + rulerGap + markerTopGutter }
    private var timelineHeight: CGFloat {
        max(1, bounds.height - rulerHeight - rulerGap - markerTopGutter - markerBottomGutter)
    }
    private var edgeHoverProximity: CGFloat { 22 }
    private var edgeGlowWidth: CGFloat {
        let selectionWidth = abs(xPosition(for: clipEndSeconds) - xPosition(for: clipStartSeconds))
        return min(max(selectionWidth * 0.18, 18), 44)
    }

    private var rulerTextColor: NSColor {
        if isDarkAppearance {
            return NSColor.white.withAlphaComponent(0.55)
        }
        return NSColor.labelColor.withAlphaComponent(0.55)
    }

    private var rulerTickColor: NSColor {
        if isDarkAppearance {
            return NSColor.white.withAlphaComponent(0.18)
        }
        return NSColor.labelColor.withAlphaComponent(0.18)
    }

    private var rulerBaselineColor: NSColor {
        if isDarkAppearance {
            return NSColor.white.withAlphaComponent(0.10)
        }
        return NSColor.labelColor.withAlphaComponent(0.10)
    }

    private func xPosition(for seconds: Double) -> CGFloat {
        let local = (seconds - visibleStartSeconds) / visibleDuration
        return CGFloat(local) * bounds.width
    }

    private func timeValue(forX x: CGFloat) -> Double {
        guard bounds.width > 0 else { return modelPlayheadSeconds }
        let ratio = min(max(0, x / bounds.width), 1.0)
        return min(totalDurationSeconds, max(0, visibleStartSeconds + (Double(ratio) * visibleDuration)))
    }

    func timelineRect() -> CGRect {
        CGRect(x: 0, y: timelineVerticalOffset, width: bounds.width, height: timelineHeight)
    }

    private func updateCursorForInteraction() {
        if hoveredMarkerID != nil {
            if !markerCursorActive {
                NSCursor.pointingHand.set()
                markerCursorActive = true
            }
            return
        }
        if markerCursorActive {
            markerCursorActive = false
        }
        if isDraggingStartEdge || isDraggingEndEdge {
            NSCursor.closedHand.set()
        } else if isStartEdgeHovered || isEndEdgeHovered {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func updateHoverState(at point: NSPoint) {
        guard !isDraggingStartEdge, !isDraggingEndEdge else { return }
        onPointerTimeChanged?(timeValue(forX: point.x))
        if let marker = markerNear(point: point) {
            hoveredMarkerID = marker.id
            isStartEdgeHovered = false
            isEndEdgeHovered = false
            updateTimelineDecorationLayers()
            updateCursorForInteraction()
            return
        }
        hoveredMarkerID = nil
        let startDistance = abs(point.x - xPosition(for: clipStartSeconds))
        let endDistance = abs(point.x - xPosition(for: clipEndSeconds))
        let nearStart = startDistance <= edgeHoverProximity
        let nearEnd = endDistance <= edgeHoverProximity
        if nearStart && nearEnd {
            isStartEdgeHovered = startDistance <= endDistance
            isEndEdgeHovered = !isStartEdgeHovered
        } else {
            isStartEdgeHovered = nearStart
            isEndEdgeHovered = nearEnd
        }
        updateTimelineDecorationLayers()
        updateCursorForInteraction()
    }

    private func snappedPlayheadFrame(for seconds: Double) -> CGRect {
        let timelineRect = timelineRect()
        let local = (seconds - visibleStartSeconds) / visibleDuration
        let x = CGFloat(local) * timelineRect.width
        let snappedX = x.rounded()
        let height = timelineRect.height + 8
        return CGRect(
            x: snappedX - (playheadDisplayWidth / 2.0),
            y: timelineRect.minY - 4,
            width: playheadDisplayWidth,
            height: height
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
        PlayheadDiagnostics.shared.noteVisualPlayheadUpdate(source: "host_apply_displayed_playhead", seconds: seconds)
    }

    private func predictedPlaybackSeconds(at hostTime: CFTimeInterval) -> Double {
        guard hasPlaybackAnchor else { return modelPlayheadSeconds }
        let elapsed = max(0, hostTime - playbackAnchorHostTime)
        let predicted = playbackAnchorSeconds + (Double(playbackAnchorRate) * elapsed)
        return min(totalDurationSeconds, max(0, predicted))
    }

    private func animateDraggedPlayhead(to seconds: Double, forceDisplaySync: Bool = false) {
        let clamped = min(totalDurationSeconds, max(0, seconds))
        lastDragSampleHostTime = CACurrentMediaTime()
        applyDisplayedPlayhead(clamped)
    }

    fileprivate func updatePlaybackAnchor(seconds: Double, rate: Float, forceDisplaySync: Bool = false) {
        let clampedSeconds = min(totalDurationSeconds, max(0, seconds))
        let now = CACurrentMediaTime()
        let priorPrediction = predictedPlaybackSeconds(at: now)
        let shouldResyncDisplay =
            forceDisplaySync ||
            !hasPlaybackAnchor ||
            abs(priorPrediction - clampedSeconds) > (1.0 / 45.0) ||
            abs(playbackAnchorRate - rate) > 0.001

        playbackAnchorSeconds = clampedSeconds
        playbackAnchorHostTime = now
        playbackAnchorRate = rate
        hasPlaybackAnchor = true

        if shouldResyncDisplay {
            applyDisplayedPlayhead(clampedSeconds)
        }
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

    private func makeRulerTicks(majorStep: Double, minorStep: Double) -> (minor: [CGFloat], major: [(CGFloat, Double)]) {
        var minorTicks: [CGFloat] = []
        var majorTicks: [(CGFloat, Double)] = []
        let epsilon = minorStep * 0.001
        var t = floor(visibleStartSeconds / minorStep) * minorStep
        var guardCount = 0
        while t <= (visibleEndSeconds + minorStep) && guardCount < 10_000 {
            let x = xPosition(for: t)
            if x >= -1 && x <= bounds.width + 1 {
                let majorRatio = t / majorStep
                if abs(majorRatio - majorRatio.rounded()) <= epsilon {
                    majorTicks.append((x, t))
                } else {
                    minorTicks.append(x)
                }
            }
            t += minorStep
            guardCount += 1
        }
        return (minorTicks, majorTicks)
    }

    private func filterLabeledMajorTicks(_ majorTicks: [(CGFloat, Double)], minLabelSpacing: CGFloat = 72) -> [(CGFloat, Double)] {
        var labeled: [(CGFloat, Double)] = []
        var lastX = -CGFloat.greatestFiniteMagnitude
        for tick in majorTicks where tick.0 - lastX >= minLabelSpacing {
            labeled.append(tick)
            lastX = tick.0
        }
        return labeled
    }

    func updateTimelineDecorationLayers() {
        let diagnosticsStart = CACurrentMediaTime()
        var hasher = Hasher()
        hasher.combine(Int((bounds.width * 10).rounded()))
        hasher.combine(Int((bounds.height * 10).rounded()))
        hasher.combine(Int((visibleStartSeconds * 1000).rounded()))
        hasher.combine(Int((visibleEndSeconds * 1000).rounded()))
        hasher.combine(Int((clipStartSeconds * 1000).rounded()))
        hasher.combine(Int((clipEndSeconds * 1000).rounded()))
        hasher.combine(isDarkAppearance)
        hasher.combine(isPointerInside)
        hasher.combine(isStartEdgeHovered)
        hasher.combine(isEndEdgeHovered)
        hasher.combine(isDraggingStartEdge)
        hasher.combine(isDraggingEndEdge)
        hasher.combine(highlightedClipBoundary)
        let decorationSignature = hasher.finalize()
        guard decorationSignature != lastDecorationSignature else { return }
        lastDecorationSignature = decorationSignature

        let timelineRect = timelineRect()
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let pixel = CGFloat(1.0 / backingScale)
        func snapToPixel(_ value: CGFloat) -> CGFloat {
            (value / pixel).rounded() * pixel
        }
        backgroundLayer.frame = bounds
        backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(isPointerInside ? 0.16 : 0.12).cgColor

        rulerBaselineLayer.frame = CGRect(x: 0, y: rulerHeight - 0.8, width: bounds.width, height: 0.8)
        rulerBaselineLayer.backgroundColor = rulerBaselineColor.cgColor

        let majorStep = rulerMajorStep(for: visibleDuration)
        let minorStep = majorStep / Double(max(1, rulerMinorDivisions(for: majorStep)))
        let ticks = makeRulerTicks(majorStep: majorStep, minorStep: minorStep)
        let path = CGMutablePath()
        for tick in ticks.minor {
            path.move(to: CGPoint(x: tick, y: rulerHeight - 4))
            path.addLine(to: CGPoint(x: tick, y: rulerHeight - 1))
        }
        for tick in ticks.major {
            path.move(to: CGPoint(x: tick.0, y: rulerHeight - 7))
            path.addLine(to: CGPoint(x: tick.0, y: rulerHeight - 1))
        }
        rulerTicksLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: rulerHeight)
        rulerTicksLayer.path = path
        rulerTicksLayer.strokeColor = rulerTickColor.cgColor
        rulerTicksLayer.lineWidth = 1

        let labeledTicks = filterLabeledMajorTicks(ticks.major)
        rulerLabelsLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: rulerHeight)
        rulerLabelsLayer.sublayers = labeledTicks.map { tick in
            let label = CATextLayer()
            label.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            label.string = NSAttributedString(
                string: rulerLabel(for: tick.1, majorStep: majorStep),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .mini), weight: .regular),
                    .foregroundColor: rulerTextColor
                ]
            )
            label.alignmentMode = .left
            label.truncationMode = .none
            label.frame = CGRect(x: tick.0 + 2, y: 0, width: 80, height: rulerHeight)
            return label
        }

        let selectionStartX = min(xPosition(for: clipStartSeconds), xPosition(for: clipEndSeconds))
        let selectionEndX = max(xPosition(for: clipStartSeconds), xPosition(for: clipEndSeconds))
        let drawSelectionStartX = snapToPixel(max(0, selectionStartX))
        let drawSelectionEndX = snapToPixel(min(bounds.width, selectionEndX))
        let drawSelectionWidth = max(0, drawSelectionEndX - drawSelectionStartX)
        let hasSelection = drawSelectionWidth > 0.5
        let selectionLocalRect = CGRect(
            x: drawSelectionStartX,
            y: 0,
            width: drawSelectionWidth,
            height: timelineRect.height
        )
        selectionFillLayer.frame = timelineRect
        selectionFillLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.38).cgColor
        selectionFillLayer.cornerRadius = UIRadius.small
        selectionFillLayer.opacity = hasSelection ? 1.0 : 0.0
        selectionFillMaskLayer.frame = selectionFillLayer.bounds
        selectionFillMaskLayer.path = hasSelection
            ? CGPath(
                roundedRect: selectionLocalRect,
                cornerWidth: UIRadius.small,
                cornerHeight: UIRadius.small,
                transform: nil
            )
            : nil

        selectionOutlineLayer.frame = timelineRect
        selectionOutlineLayer.opacity = hasSelection ? 1.0 : 0.0
        selectionOutlineLayer.lineWidth = (isStartEdgeHovered || isEndEdgeHovered || isDraggingStartEdge || isDraggingEndEdge) ? 3.4 : 3.0
        selectionOutlineLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(isPointerInside ? 0.98 : 0.92).cgColor
        if hasSelection {
            selectionOutlineLayer.path = CGPath(
                roundedRect: selectionLocalRect,
                cornerWidth: UIRadius.small,
                cornerHeight: UIRadius.small,
                transform: nil
            )
        } else {
            selectionOutlineLayer.path = nil
        }

        selectionFlashLayer.frame = timelineRect
        selectionFlashLayer.cornerRadius = UIRadius.small
        selectionFlashLayer.backgroundColor = NSColor.white.withAlphaComponent(1.0).cgColor
        selectionFlashLayer.opacity = hasSelection ? selectionFlashLayer.opacity : 0.0
        selectionFlashMaskLayer.frame = selectionFlashLayer.bounds
        selectionFlashMaskLayer.path = hasSelection
            ? CGPath(
                roundedRect: selectionLocalRect,
                cornerWidth: UIRadius.small,
                cornerHeight: UIRadius.small,
                transform: nil
            )
            : nil

        let startX = snapToPixel(xPosition(for: clipStartSeconds))
        let endX = snapToPixel(xPosition(for: clipEndSeconds))
        let edgeWidth = edgeGlowWidth
        let edgeHeight = timelineRect.height
        let startGlowOpacity: Float = isDraggingStartEdge ? 1.0 : (isStartEdgeHovered ? 0.78 : 0.0)
        let endGlowOpacity: Float = isDraggingEndEdge ? 1.0 : (isEndEdgeHovered ? 0.78 : 0.0)
        startEdgeGlowLayer.frame = CGRect(x: startX, y: timelineRect.minY, width: edgeWidth, height: edgeHeight)
        startEdgeGlowLayer.colors = [NSColor.controlAccentColor.withAlphaComponent(CGFloat(startGlowOpacity)).cgColor, NSColor.clear.cgColor]
        let targetStartGlowOpacity: Float = hasSelection ? startGlowOpacity : 0
        animateLayerOpacityIfNeeded(
            startEdgeGlowLayer,
            from: lastStartEdgeGlowOpacity,
            to: targetStartGlowOpacity,
            duration: 0.16
        )
        startEdgeGlowLayer.opacity = targetStartGlowOpacity
        lastStartEdgeGlowOpacity = targetStartGlowOpacity
        endEdgeGlowLayer.frame = CGRect(x: max(startX, endX - edgeWidth), y: timelineRect.minY, width: edgeWidth, height: edgeHeight)
        endEdgeGlowLayer.colors = [NSColor.clear.cgColor, NSColor.controlAccentColor.withAlphaComponent(CGFloat(endGlowOpacity)).cgColor]
        let targetEndGlowOpacity: Float = hasSelection ? endGlowOpacity : 0
        animateLayerOpacityIfNeeded(
            endEdgeGlowLayer,
            from: lastEndEdgeGlowOpacity,
            to: targetEndGlowOpacity,
            duration: 0.16
        )
        endEdgeGlowLayer.opacity = targetEndGlowOpacity
        lastEndEdgeGlowOpacity = targetEndGlowOpacity

        let startPulseOpacity: Float = highlightedClipBoundary == .start ? 0.95 : 0
        let endPulseOpacity: Float = highlightedClipBoundary == .end ? 0.95 : 0
        startBoundaryPulseLayer.frame = CGRect(x: startX, y: timelineRect.minY, width: edgeWidth, height: edgeHeight)
        startBoundaryPulseLayer.colors = [NSColor.controlAccentColor.withAlphaComponent(CGFloat(startPulseOpacity)).cgColor, NSColor.clear.cgColor]
        let targetStartPulseOpacity: Float = hasSelection ? startPulseOpacity : 0
        animateLayerOpacityIfNeeded(
            startBoundaryPulseLayer,
            from: lastStartBoundaryPulseOpacity,
            to: targetStartPulseOpacity,
            duration: 0.16
        )
        startBoundaryPulseLayer.opacity = targetStartPulseOpacity
        lastStartBoundaryPulseOpacity = targetStartPulseOpacity
        endBoundaryPulseLayer.frame = CGRect(x: max(startX, endX - edgeWidth), y: timelineRect.minY, width: edgeWidth, height: edgeHeight)
        endBoundaryPulseLayer.colors = [NSColor.clear.cgColor, NSColor.controlAccentColor.withAlphaComponent(CGFloat(endPulseOpacity)).cgColor]
        let targetEndPulseOpacity: Float = hasSelection ? endPulseOpacity : 0
        animateLayerOpacityIfNeeded(
            endBoundaryPulseLayer,
            from: lastEndBoundaryPulseOpacity,
            to: targetEndPulseOpacity,
            duration: 0.16
        )
        endBoundaryPulseLayer.opacity = targetEndPulseOpacity
        lastEndBoundaryPulseOpacity = targetEndPulseOpacity
        PlayheadDiagnostics.shared.noteDecorationUpdate(duration: CACurrentMediaTime() - diagnosticsStart)
    }

    private func animateLayerOpacityIfNeeded(_ layer: CALayer, from oldValue: Float, to newValue: Float, duration: CFTimeInterval) {
        guard oldValue != newValue else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? oldValue
        animation.toValue = newValue
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: "opacityTransition")
    }

    func triggerSelectionFlash() {
        let flashIn = CABasicAnimation(keyPath: "opacity")
        flashIn.fromValue = 0.0
        flashIn.toValue = 0.52
        flashIn.duration = 0.14
        flashIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flashIn.autoreverses = false
        flashIn.isRemovedOnCompletion = true
        selectionFlashLayer.add(flashIn, forKey: "selectionFlashIn")

        let flashOut = CABasicAnimation(keyPath: "opacity")
        flashOut.beginTime = CACurrentMediaTime() + 0.26
        flashOut.fromValue = 0.52
        flashOut.toValue = 0.0
        flashOut.duration = 0.34
        flashOut.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flashOut.fillMode = .both
        flashOut.isRemovedOnCompletion = true
        selectionFlashLayer.add(flashOut, forKey: "selectionFlashOut")
    }

    private func updateInteractiveDrag(at point: NSPoint, forceCommit: Bool) {
        let target = timeValue(forX: point.x)
        PlayheadDiagnostics.shared.noteScrubInput(source: "host_interactive_drag", seconds: target)
        dragPlayheadSeconds = target
        animateDraggedPlayhead(to: target, forceDisplaySync: forceCommit && lastDragSampleHostTime == 0)
        onPlayheadDragEdgePan?(point.x, bounds.width)

        let now = CACurrentMediaTime()
        // Keep the visible line immediate, but reduce actual seek pressure while dragging.
        // Lower seek cadence generally feels smoother than trying to seek on every drag event.
        let commitInterval = 1.0 / 30.0
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
        updateHoverState(at: point)
        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        onHoverChanged?(true)
        updateTimelineDecorationLayers()
        updateHoverState(at: convert(event.locationInWindow, from: nil))
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredMarkerID = nil
        isPointerInside = false
        isStartEdgeHovered = false
        isEndEdgeHovered = false
        onHoverChanged?(false)
        onPointerTimeChanged?(nil)
        updateTimelineDecorationLayers()
        updateCursorForInteraction()
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let marker = markerNear(point: point) {
            isDraggingPlayhead = true
            lastDragCommitTimestamp = 0
            lastDragSampleHostTime = 0
            onPlayheadDragStateChanged?(true)
            dragPlayheadSeconds = marker.seconds
            applyDisplayedPlayhead(marker.seconds)
            onInteractiveSeek?(marker.seconds, true)
            updateLivePlaybackTimerState()
            return
        }

        let startDistance = abs(point.x - xPosition(for: clipStartSeconds))
        let endDistance = abs(point.x - xPosition(for: clipEndSeconds))
        if startDistance <= edgeHoverProximity && startDistance <= endDistance {
            isDraggingStartEdge = true
            onClipBoundaryDragStateChanged?(true)
            isStartEdgeHovered = true
            isEndEdgeHovered = false
            updateTimelineDecorationLayers()
            updateCursorForInteraction()
            onSetStart?(min(max(0, timeValue(forX: point.x)), clipEndSeconds))
            return
        }
        if endDistance <= edgeHoverProximity {
            isDraggingEndEdge = true
            onClipBoundaryDragStateChanged?(true)
            isEndEdgeHovered = true
            isStartEdgeHovered = false
            updateTimelineDecorationLayers()
            updateCursorForInteraction()
            onSetEnd?(max(min(totalDurationSeconds, timeValue(forX: point.x)), clipStartSeconds))
            return
        }

        isDraggingPlayhead = true
        lastDragCommitTimestamp = 0
        lastDragSampleHostTime = 0
        onPlayheadDragStateChanged?(true)

        updateInteractiveDrag(at: point, forceCommit: true)
        updateLivePlaybackTimerState()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isDraggingStartEdge {
            onSetStart?(min(max(0, timeValue(forX: point.x)), clipEndSeconds))
            onPointerTimeChanged?(timeValue(forX: point.x))
            return
        }
        if isDraggingEndEdge {
            onSetEnd?(max(min(totalDurationSeconds, timeValue(forX: point.x)), clipStartSeconds))
            onPointerTimeChanged?(timeValue(forX: point.x))
            return
        }
        guard isDraggingPlayhead else {
            super.mouseDragged(with: event)
            return
        }
        onPlayheadDragEdgePan?(point.x, bounds.width)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isDraggingStartEdge {
            onSetStart?(min(max(0, timeValue(forX: point.x)), clipEndSeconds))
            isDraggingStartEdge = false
            onClipBoundaryDragStateChanged?(false)
            updateHoverState(at: point)
            updateTimelineDecorationLayers()
            return
        }
        if isDraggingEndEdge {
            onSetEnd?(max(min(totalDurationSeconds, timeValue(forX: point.x)), clipStartSeconds))
            isDraggingEndEdge = false
            onClipBoundaryDragStateChanged?(false)
            updateHoverState(at: point)
            updateTimelineDecorationLayers()
            return
        }
        guard isDraggingPlayhead else {
            super.mouseUp(with: event)
            return
        }
        updateInteractiveDrag(at: point, forceCommit: true)
        isDraggingPlayhead = false
        dragPlayheadSeconds = nil
        lastDragSampleHostTime = 0
        playheadLayer.removeAnimation(forKey: "dragPlayheadPosition")
        playheadLayer.removeAnimation(forKey: "dragPlayheadOpacity")
        onPlayheadDragStateChanged?(false)
        updateLivePlaybackTimerState()
    }

    override func layout() {
        super.layout()
        surfaceLayer.frame = bounds
        backgroundLayer.frame = bounds
        waveformClipLayer.frame = timelineRect()
        waveformLayer.frame = waveformClipLayer.bounds
        markerContainerLayer.frame = timelineRect()
        updateTimelineDecorationLayers()
        PlayheadDiagnostics.shared.noteLayoutPass(source: "waveform_host_layout")
    }

    private func startLivePlaybackTimerIfNeeded() {
        guard livePlaybackDisplayLink == nil else { return }

        var displayLink: CVDisplayLink?
        let createStatus = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard createStatus == kCVReturnSuccess, let displayLink else { return }

        let callbackStatus = CVDisplayLinkSetOutputCallback(
            displayLink,
            { _, _, _, _, _, userInfo in
                guard let userInfo else { return kCVReturnSuccess }
                let hostView = Unmanaged<WaveformRasterHostView>.fromOpaque(userInfo).takeUnretainedValue()
                hostView.scheduleLivePlaybackTick()
                return kCVReturnSuccess
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        guard callbackStatus == kCVReturnSuccess else {
            return
        }

        livePlaybackDisplayLink = displayLink
        CVDisplayLinkStart(displayLink)
    }

    private func stopLivePlaybackTimer() {
        if let livePlaybackDisplayLink {
            CVDisplayLinkStop(livePlaybackDisplayLink)
            self.livePlaybackDisplayLink = nil
        }
        hasPendingDisplayLinkTick = false
    }

    func updateLivePlaybackTimerState() {
        let isPlaying = (player?.rate ?? 0) != 0
        let shouldRunDisplayLink = isDraggingPlayhead || isPlaying

        guard shouldRunDisplayLink else {
            stopLivePlaybackTimer()
            if player != nil {
                updatePlaybackAnchor(seconds: modelPlayheadSeconds, rate: 0, forceDisplaySync: true)
            } else {
                hasPlaybackAnchor = false
                playbackAnchorRate = 0
            }
            return
        }

        startLivePlaybackTimerIfNeeded()
    }

    private func tickLivePlayhead() {
        if isDraggingPlayhead, let window {
            let sampledPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            updateInteractiveDrag(at: sampledPoint, forceCommit: false)
            return
        }

        guard let player, player.rate != 0 else {
            stopLivePlaybackTimer()
            return
        }
        let predicted = predictedPlaybackSeconds(at: CACurrentMediaTime())
        applyDisplayedPlayhead(predicted)
    }

    private func scheduleLivePlaybackTick() {
        guard !hasPendingDisplayLinkTick else { return }
        hasPendingDisplayLinkTick = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingDisplayLinkTick = false
            self.tickLivePlayhead()
        }
    }
}

final class WaveformRasterCoordinator {
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
    var lastQuickExportFlashToken: Int = 0
    var lastStaticTimelineSignature: Int?

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
        lastStaticTimelineSignature = nil
        return true
    }

    func image(for zoomBucket: Double) -> CGImage? {
        if let cached = cachedBucketImages[zoomBucket] {
            return cached
        }
        guard !cachedSamples.isEmpty else { return nil }
        let diagnosticsStart = CACurrentMediaTime()
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
        let rebuildDuration = CACurrentMediaTime() - diagnosticsStart
        Task { @MainActor in
            PlayheadDiagnostics.shared.noteWaveformImageRebuild(duration: rebuildDuration)
        }
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
            var sumSquares = 0.0
            var sampleCounter = 0
            var i = startIndex
            while i <= endIndex {
                let sample = samples[i]
                peak = max(peak, sample)
                sumSquares += sample * sample
                sampleCounter += 1
                i += 1
            }

            guard sampleCounter > 0 else {
                peaks[x] = 0
                continue
            }

            // When zoomed out, a pure max envelope overstates brief spikes and stops
            // matching the perceived loudness of the audio. Blend toward RMS for
            // downsampled buckets, but keep some transient energy so short events
            // still show up.
            if endIndex > startIndex {
                let rms = sqrt(sumSquares / Double(sampleCounter))
                peaks[x] = max(rms, peak * 0.4)
            } else {
                peaks[x] = peak
            }
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

struct WaveformRasterLayerView: NSViewRepresentable, Equatable {
    let player: AVPlayer
    let sourceSessionID: UUID
    let samples: [Double]
    let zoomLevel: Double
    let renderBuckets: [Double]
    let clipStartSeconds: Double
    let clipEndSeconds: Double
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
    let highlightedClipBoundary: ClipBoundaryHighlight?
    let quickExportFlashToken: Int
    let onMarkerSeek: (Double) -> Void
    let onInteractiveSeek: (Double, Bool) -> Void
    let onPlayheadDragStateChanged: (Bool) -> Void
    let onClipBoundaryDragStateChanged: (Bool) -> Void
    let onPlayheadDragEdgePan: (CGFloat, CGFloat) -> Void
    let onSetStart: (Double) -> Void
    let onSetEnd: (Double) -> Void
    let onHoverChanged: (Bool) -> Void
    let onPointerTimeChanged: (Double?) -> Void

    static func == (lhs: WaveformRasterLayerView, rhs: WaveformRasterLayerView) -> Bool {
        lhs.sourceSessionID == rhs.sourceSessionID &&
        ObjectIdentifier(lhs.player) == ObjectIdentifier(rhs.player) &&
        lhs.samples.count == rhs.samples.count &&
        abs(lhs.zoomLevel - rhs.zoomLevel) < 0.0001 &&
        lhs.renderBuckets == rhs.renderBuckets &&
        abs(lhs.clipStartSeconds - rhs.clipStartSeconds) < 0.0001 &&
        abs(lhs.clipEndSeconds - rhs.clipEndSeconds) < 0.0001 &&
        abs(lhs.totalDurationSeconds - rhs.totalDurationSeconds) < 0.0001 &&
        abs(lhs.visibleStartSeconds - rhs.visibleStartSeconds) < 0.0001 &&
        abs(lhs.visibleEndSeconds - rhs.visibleEndSeconds) < 0.0001 &&
        lhs.isDarkAppearance == rhs.isDarkAppearance &&
        abs(lhs.playheadSeconds - rhs.playheadSeconds) < 0.0001 &&
        abs(lhs.playheadJumpFromSeconds - rhs.playheadJumpFromSeconds) < 0.0001 &&
        lhs.playheadJumpAnimationToken == rhs.playheadJumpAnimationToken &&
        lhs.isPlayheadCaptureFlashing == rhs.isPlayheadCaptureFlashing &&
        lhs.captureMarkers == rhs.captureMarkers &&
        lhs.highlightedMarkerID == rhs.highlightedMarkerID &&
        lhs.highlightedClipBoundary == rhs.highlightedClipBoundary &&
        lhs.quickExportFlashToken == rhs.quickExportFlashToken
    }

    func makeCoordinator() -> WaveformRasterCoordinator {
        WaveformRasterCoordinator()
    }

    func makeNSView(context: Context) -> WaveformRasterHostView {
        let view = WaveformRasterHostView()
        view.onMarkerSeek = onMarkerSeek
        view.onInteractiveSeek = onInteractiveSeek
        view.onPlayheadDragStateChanged = onPlayheadDragStateChanged
        view.onClipBoundaryDragStateChanged = onClipBoundaryDragStateChanged
        view.onPlayheadDragEdgePan = onPlayheadDragEdgePan
        view.onSetStart = onSetStart
        view.onSetEnd = onSetEnd
        view.onHoverChanged = onHoverChanged
        view.onPointerTimeChanged = onPointerTimeChanged
        return view
    }

    func updateNSView(_ nsView: WaveformRasterHostView, context: Context) {
        let diagnosticsStart = CACurrentMediaTime()
        nsView.onMarkerSeek = onMarkerSeek
        nsView.onInteractiveSeek = onInteractiveSeek
        nsView.onPlayheadDragStateChanged = onPlayheadDragStateChanged
        nsView.onClipBoundaryDragStateChanged = onClipBoundaryDragStateChanged
        nsView.onPlayheadDragEdgePan = onPlayheadDragEdgePan
        nsView.onSetStart = onSetStart
        nsView.onSetEnd = onSetEnd
        nsView.onHoverChanged = onHoverChanged
        nsView.onPointerTimeChanged = onPointerTimeChanged
        nsView.player = player
        nsView.clipStartSeconds = clipStartSeconds
        nsView.clipEndSeconds = clipEndSeconds
        nsView.modelPlayheadSeconds = playheadSeconds
        nsView.isDarkAppearance = isDarkAppearance
        nsView.highlightedClipBoundary = highlightedClipBoundary
        context.coordinator.setZoomRenderBuckets(renderBuckets)

        let duration = max(0.0001, totalDurationSeconds)
        let rawStartNorm = min(max(0, visibleStartSeconds / duration), 1.0)
        let rawEndNorm = min(max(rawStartNorm + 0.000001, visibleEndSeconds / duration), 1.0)
        let zoomBucket = context.coordinator.bestZoomRenderBucket(for: zoomLevel)
        var staticTimelineHasher = Hasher()
        staticTimelineHasher.combine(sourceSessionID)
        staticTimelineHasher.combine(samples.count)
        staticTimelineHasher.combine(isDarkAppearance)
        staticTimelineHasher.combine(Int((totalDurationSeconds * 1000).rounded()))
        staticTimelineHasher.combine(Int((visibleStartSeconds * 1000).rounded()))
        staticTimelineHasher.combine(Int((visibleEndSeconds * 1000).rounded()))
        staticTimelineHasher.combine(Int((clipStartSeconds * 1000).rounded()))
        staticTimelineHasher.combine(Int((clipEndSeconds * 1000).rounded()))
        staticTimelineHasher.combine(Int((zoomBucket * 1000).rounded()))
        staticTimelineHasher.combine(highlightedMarkerID)
        staticTimelineHasher.combine(highlightedClipBoundary)
        staticTimelineHasher.combine(Int((nsView.bounds.width * 10).rounded()))
        staticTimelineHasher.combine(Int((nsView.bounds.height * 10).rounded()))
        staticTimelineHasher.combine(captureMarkers.count)
        for marker in captureMarkers {
            staticTimelineHasher.combine(marker.id)
            staticTimelineHasher.combine(Int((marker.seconds * 1000).rounded()))
        }
        let staticTimelineSignature = staticTimelineHasher.finalize()
        let needsFullTimelineUpdate = context.coordinator.lastStaticTimelineSignature != staticTimelineSignature
        var image: CGImage?

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let timelineRect = nsView.timelineRect()

        if !nsView.bounds.equalTo(context.coordinator.lastAppliedBounds) {
            nsView.surfaceLayer.frame = nsView.bounds
            nsView.backgroundLayer.frame = nsView.bounds
            nsView.waveformClipLayer.frame = timelineRect
            nsView.waveformLayer.frame = nsView.waveformClipLayer.bounds
            nsView.markerContainerLayer.frame = timelineRect
            context.coordinator.lastAppliedBounds = nsView.bounds
        }

        if needsFullTimelineUpdate {
            let didRebuildImage = context.coordinator.rebuildImageIfNeeded(
                sessionID: sourceSessionID,
                samples: samples,
                isDarkAppearance: isDarkAppearance
            )

            nsView.updateTimelineDecorationLayers()

            if !context.coordinator.cachedSamples.isEmpty {
                image = context.coordinator.image(for: zoomBucket)
            }

            if let image,
               (didRebuildImage || context.coordinator.lastAppliedZoomBucket != zoomBucket || nsView.waveformLayer.contents == nil) {
                nsView.waveformLayer.contents = image
                context.coordinator.lastAppliedZoomBucket = zoomBucket
                nsView.waveformLayer.magnificationFilter = zoomBucket >= 32 ? .nearest : .linear
                nsView.waveformLayer.minificationFilter = .linear
            }

            if image == nil {
                nsView.waveformLayer.contents = nil
            } else {
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
                    let isContinuousViewportInteraction = lastUpdate > 0 && (now - lastUpdate) < 0.08
                    if oldRect != .null {
                        let deltaX = abs(newContentsRect.origin.x - oldRect.origin.x)
                        let deltaWidth = abs(newContentsRect.width - oldRect.width)
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
            }
            context.coordinator.lastStaticTimelineSignature = staticTimelineSignature
        }

        let visibleDuration = max(0.0001, visibleEndSeconds - visibleStartSeconds)
        let width = nsView.bounds.width
        func xPosition(for seconds: Double) -> CGFloat {
            let local = seconds - visibleStartSeconds
            return CGFloat(local / visibleDuration) * timelineRect.width
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
        let isInterpolatingPlayback = nsView.dragPlayheadSeconds == nil && player.rate != 0
        let hostOwnsPlayheadDisplay = nsView.dragPlayheadSeconds != nil || isInterpolatingPlayback
        if nsView.dragPlayheadSeconds == nil {
            nsView.updatePlaybackAnchor(
                seconds: playheadSeconds,
                rate: player.rate,
                forceDisplaySync: !isInterpolatingPlayback
            )
        }
        nsView.updateLivePlaybackTimerState()
        let playheadHeight = timelineRect.height + 8
        let targetPlayheadFrame = CGRect(
            x: playheadX - (playheadWidth / 2.0),
            y: timelineRect.minY - 4,
            width: playheadWidth,
            height: playheadHeight
        )
        if !hostOwnsPlayheadDisplay, playheadJumpAnimationToken != context.coordinator.lastPlayheadJumpAnimationToken {
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
        }
        context.coordinator.lastPlayheadJumpAnimationToken = playheadJumpAnimationToken

        if !hostOwnsPlayheadDisplay {
            nsView.playheadLayer.frame = targetPlayheadFrame
            let playheadVisible = playheadX >= -6 && playheadX <= (width + 6)
            nsView.playheadLayer.opacity = playheadVisible ? 1.0 : 0.0
        }
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

        if quickExportFlashToken != context.coordinator.lastQuickExportFlashToken {
            nsView.triggerSelectionFlash()
            context.coordinator.lastQuickExportFlashToken = quickExportFlashToken
        }

        if needsFullTimelineUpdate {
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
                let markerLayoutStart = CACurrentMediaTime()
                var markerHotspots: [WaveformRasterHostView.MarkerHotspot] = []
                var markerLayersByID: [UUID: CALayer] = [:]
                markerContainer.sublayers = visibleMarkers.map { _, marker in
                    let markerX = snapToPixel(xPosition(for: marker.seconds))
                    markerHotspots.append(.init(id: marker.id, seconds: marker.seconds, x: markerX))
                    let isHighlighted = marker.id == highlightedMarkerID
                    let pinColor = NSColor.systemOrange.withAlphaComponent(isHighlighted ? 1.0 : 0.9)

                    let pin = CALayer()
                    pin.frame = CGRect(
                        x: markerX - (isHighlighted ? 4.5 : 4.0),
                        y: -2,
                        width: isHighlighted ? 9 : 8,
                        height: timelineRect.height + 6
                    )
                    pin.setValue(isHighlighted, forKey: "isHighlighted")
                    pin.isGeometryFlipped = true

                    let head = CALayer()
                    head.backgroundColor = pinColor.cgColor
                    head.frame = CGRect(x: 0, y: 0, width: isHighlighted ? 9 : 8, height: isHighlighted ? 9 : 8)
                    head.cornerRadius = head.bounds.width / 2
                    pin.addSublayer(head)

                    let stem = CALayer()
                    stem.backgroundColor = NSColor.systemOrange.withAlphaComponent(isHighlighted ? 0.96 : 0.8).cgColor
                    let stemWidth: CGFloat = isHighlighted ? 2.6 : 2.0
                    stem.frame = CGRect(x: (head.bounds.width - stemWidth) / 2.0, y: head.frame.maxY, width: stemWidth, height: timelineRect.height + 4)
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
                PlayheadDiagnostics.shared.noteMarkerLayout(duration: CACurrentMediaTime() - markerLayoutStart)
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
        }

        CATransaction.commit()
        PlayheadDiagnostics.shared.noteUpdateNSView(duration: CACurrentMediaTime() - diagnosticsStart, didFullTimelineUpdate: needsFullTimelineUpdate)
    }
}
