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
    private var livePlaybackDisplayLink: CVDisplayLink?
    private var hasPendingDisplayLinkTick = false
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

struct WaveformRasterLayerView: NSViewRepresentable, Equatable {
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
