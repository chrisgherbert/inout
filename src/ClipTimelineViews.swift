import AppKit
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine
import UserNotifications

struct ClipToolView: View {
    @ObservedObject var model: WorkspaceViewModel
    let isCompactLayout: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.undoManager) private var undoManager

    @State private var player = AVPlayer()
    @State private var playheadSeconds: Double = 0
    @State private var playerDurationSeconds: Double = 0
    @State private var waveformSamples: [Double] = []
    @State private var isWaveformLoading = false
    @State private var waveformTask: Task<Void, Never>?
    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var mouseDownMonitor: Any?
    @State private var middleMousePanMonitor: Any?
    @State private var timelineZoom: Double = 1.0
    @State private var viewportStartSeconds: Double = 0
    @State private var isViewportManuallyControlled = false
    @State private var isTimelineHovered = false
    @State private var isWaveformHovered = false
    @State private var isOptionKeyPressed = false
    @State private var timelineInteractiveWidth: CGFloat = 1
    @State private var isMiddleMousePanning = false
    @State private var middleMousePanLastWindowX: CGFloat?
    @State private var loadedSourcePath: String?
    @State private var playheadVisualSeconds: Double = 0
    @State private var suppressVisualPlayheadSyncUntil: Date = .distantPast
    @State private var playheadJumpAnimationToken: Int = 0
    @State private var playheadJumpFromSeconds: Double = 0
    @State private var isPlayheadDragActive = false
    @State private var playheadDragLocationX: CGFloat?
    @State private var playheadDragWidth: CGFloat = 0
    @State private var playheadDragAutoPanTask: Task<Void, Never>?
    @State private var keyboardPanTask: Task<Void, Never>?
    @State private var playheadCopyFlash = false
    @State private var lastSharedPlayheadSyncTimestamp: CFTimeInterval = 0
    @State private var timelinePointerSeconds: Double?
    @State private var clipWindow: NSWindow?
    @State private var clipContentHeight: CGFloat = 0
    @State private var playerTimeObserverToken: Any?
    @State private var lastPlaybackUIUpdateTimestamp: CFTimeInterval = 0
    @State private var lastPlaybackFollowUpdateTimestamp: CFTimeInterval = 0
    @SceneStorage("clip.playerHeight") private var storedPlayerHeight: Double = 0
    @State private var playerResizeStartHeight: CGFloat?
    @State private var playerResizeStartGlobalY: CGFloat?
    @State private var livePlayerHeight: CGFloat?
    @State private var importURLText: String = ""
    @State private var importURLPreset: URLDownloadPreset = .compatibleBest
    @State private var importURLSaveMode: URLDownloadSaveLocationMode = .askEachTime
    @State private var importCustomFolderPath: String = ""
    @State private var showURLImportAdvancedOptions = false
    @State private var emptyStateURLText: String = ""
    @State private var isEmptyDropTargeted = false
    @FocusState private var isImportURLFieldFocused: Bool
    private var allowedTimelineZoomLevels: [Double] {
        let duration = totalDurationSeconds
        if duration <= 300 {
            return [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 320, 384]
        }
        if duration <= 1_800 {
            return [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 160, 192, 256]
        }
        if duration <= 7_200 {
            return [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 160]
        }
        return [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128]
    }

    @State private var lastInteractiveSeekSeconds: Double = -1

    private func syncVisualPlayheadImmediately(_ value: Double) {
        playheadVisualSeconds = value
        playheadJumpFromSeconds = value
        suppressVisualPlayheadSyncUntil = .distantPast
    }

    private func springAnimateVisualPlayhead(to value: Double) {
        playheadJumpFromSeconds = playheadVisualSeconds
        playheadVisualSeconds = value
        playheadJumpAnimationToken &+= 1
        suppressVisualPlayheadSyncUntil = Date().addingTimeInterval(0.22)
    }

    private func nearestZoomIndex(for value: Double) -> Int {
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, level) in allowedTimelineZoomLevels.enumerated() {
            let distance = abs(level - value)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func setTimelineZoomIndex(_ index: Int) {
        let clamped = min(max(0, index), allowedTimelineZoomLevels.count - 1)
        let next = allowedTimelineZoomLevels[clamped]
        guard abs(timelineZoom - next) > 0.0001 else { return }

        let oldZoom = max(1.0, timelineZoom)
        let oldWindow = max(0.25, totalDurationSeconds / oldZoom)
        let oldStart = oldZoom <= 1 ? 0 : clampedViewportStart(viewportStartSeconds)

        let playheadAnchorSeconds = min(max(0, playheadVisualSeconds), totalDurationSeconds)
        let anchorSeconds: Double = {
            if isWaveformHovered, let pointer = timelinePointerSeconds {
                return min(max(0, pointer), totalDurationSeconds)
            }
            return playheadAnchorSeconds
        }()
        let usingPointerAnchor = isWaveformHovered && timelinePointerSeconds != nil
        let playheadVisibleInCurrentWindow = playheadSeconds >= oldStart && playheadSeconds <= (oldStart + oldWindow)
        let anchorRatio: Double
        if oldZoom <= 1.0001 {
            // First zoom step from "fit" should focus around the chosen anchor time.
            anchorRatio = 0.5
        } else if usingPointerAnchor {
            // Keep cursor-anchored zoom stable under the mouse.
            anchorRatio = min(max((anchorSeconds - oldStart) / oldWindow, 0), 1)
        } else if playheadVisibleInCurrentWindow {
            // Keep current playhead screen position when it is already visible.
            anchorRatio = min(max((anchorSeconds - oldStart) / oldWindow, 0), 1)
        } else {
            // If playhead is offscreen, re-center around it so zoom intent remains clear.
            anchorRatio = 0.5
        }

        timelineZoom = next
        if next <= 1 {
            viewportStartSeconds = 0
            isViewportManuallyControlled = false
            return
        }

        let newWindow = max(0.25, totalDurationSeconds / max(1.0, next))
        let newStart: Double
        if oldZoom <= 1.0001 {
            // Deterministic first zoom step from "fit": center around anchor.
            newStart = anchorSeconds - (newWindow * 0.5)
        } else {
            newStart = anchorSeconds - (anchorRatio * newWindow)
        }
        viewportStartSeconds = clampedViewportStart(newStart)
        isViewportManuallyControlled = true
    }

    private func clampTimelineZoomToAllowedLevels() {
        let idx = nearestZoomIndex(for: timelineZoom)
        let clamped = allowedTimelineZoomLevels[idx]
        if abs(clamped - timelineZoom) > 0.0001 {
            timelineZoom = clamped
        }
    }

    private var timelineZoomIndex: Int {
        nearestZoomIndex(for: timelineZoom)
    }

    private var fastClipFormats: [ClipFormat] { [.mp4, .mov] }
    private var advancedClipFormats: [ClipFormat] { ClipFormat.allCases }

    private func effectivePlayheadSeconds() -> Double {
        let current = CMTimeGetSeconds(player.currentTime())
        if current.isFinite {
            return max(0, min(current, max(playerDurationSeconds, model.sourceDurationSeconds)))
        }
        return playheadSeconds
    }

    private func installPlayerTimeObserverIfNeeded() {
        guard playerTimeObserverToken == nil else { return }
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        playerTimeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let current = CMTimeGetSeconds(time)
            if current.isFinite {
                let newPlayhead = max(0, current)
                let didMove = abs(newPlayhead - playheadSeconds) > (1.0 / 240.0)

                if didMove {
                    let now = CACurrentMediaTime()
                    let isPlaying = player.rate != 0
                    let uiUpdateInterval = isPlaying ? (1.0 / 8.0) : (1.0 / 30.0)
                    if !isPlaying || (now - lastPlaybackUIUpdateTimestamp) >= uiUpdateInterval {
                        playheadSeconds = newPlayhead
                        if Date() >= suppressVisualPlayheadSyncUntil {
                            playheadVisualSeconds = newPlayhead
                        }
                        lastPlaybackUIUpdateTimestamp = now
                    }
                    // Avoid high-frequency @Published writes while playback is active.
                    // Persist shared playhead state only while paused or on explicit actions.
                    if !isPlaying {
                        syncSharedPlayheadStateIfNeeded(newPlayhead, force: false, updateAlignment: true)
                    }
                }

                if player.rate != 0 {
                    // While playing, do not forcibly override manual viewport panning.
                    // Follow only when viewport is not currently under manual control,
                    // and throttle follow updates to avoid layout churn.
                    let shouldFollow = !isViewportManuallyControlled
                    if shouldFollow {
                        let now = CACurrentMediaTime()
                        if (now - lastPlaybackFollowUpdateTimestamp) >= (1.0 / 10.0) {
                            updateViewportForPlayhead(shouldFollow: true)
                            lastPlaybackFollowUpdateTimestamp = now
                        }
                    }
                } else if didMove {
                    updateViewportForPlayhead(shouldFollow: false)
                }
            }

            let currentDuration = CMTimeGetSeconds(player.currentItem?.duration ?? .invalid)
            if currentDuration.isFinite && currentDuration > 0,
               abs(currentDuration - playerDurationSeconds) > (1.0 / 120.0) {
                playerDurationSeconds = currentDuration
            }
        }
    }

    private func removePlayerTimeObserver() {
        guard let token = playerTimeObserverToken else { return }
        player.removeTimeObserver(token)
        playerTimeObserverToken = nil
        lastPlaybackUIUpdateTimestamp = 0
        lastPlaybackFollowUpdateTimestamp = 0
    }

    private func loadPlayerItem() {
        guard let sourceURL = model.sourceURL else {
            removePlayerTimeObserver()
            player.replaceCurrentItem(with: nil)
            playheadSeconds = 0
            playheadVisualSeconds = 0
            playerDurationSeconds = 0
            loadedSourcePath = nil
            waveformTask?.cancel()
            waveformSamples = []
            isWaveformLoading = false
            return
        }

        if loadedSourcePath == sourceURL.path, player.currentItem != nil {
            let duration = max(playerDurationSeconds, model.sourceDurationSeconds)
            let restored = max(0, min(model.clipPlayheadSeconds, duration))
            if abs(playheadSeconds - restored) > (1.0 / 120.0) {
                seekPlayer(to: restored)
            } else {
                syncVisualPlayheadImmediately(restored)
            }
            return
        }

        loadedSourcePath = sourceURL.path
        let item = AVPlayerItem(url: sourceURL)
        player.replaceCurrentItem(with: item)
        installPlayerTimeObserverIfNeeded()
        let duration = CMTimeGetSeconds(item.asset.duration)
        playerDurationSeconds = duration.isFinite && duration > 0 ? duration : model.sourceDurationSeconds
        let restored = max(0, min(model.clipPlayheadSeconds, max(playerDurationSeconds, model.sourceDurationSeconds)))
        playheadSeconds = restored
        syncVisualPlayheadImmediately(restored)
        viewportStartSeconds = 0
        clampTimelineZoomToAllowedLevels()
        player.seek(to: CMTime(seconds: restored, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        loadWaveform(for: sourceURL)
    }

    private func loadWaveform(for url: URL) {
        waveformTask?.cancel()

        // Keep long timelines detailed when zoomed in: higher bucket density than real-time display rate.
        let targetSampleCount = Int(min(240_000, max(12_000, model.sourceDurationSeconds * 120.0)))

        if let cachedSamples = model.waveformSamplesFromCache(for: url, sampleCount: targetSampleCount), !cachedSamples.isEmpty {
            waveformSamples = cachedSamples
            isWaveformLoading = false
            return
        }

        waveformSamples = []
        isWaveformLoading = true

        waveformTask = Task.detached(priority: .userInitiated) {
            let samples = generateWaveformSamples(for: url, sampleCount: targetSampleCount)
            await MainActor.run {
                self.model.cacheWaveformSamples(samples, for: url, sampleCount: targetSampleCount)
                self.waveformSamples = samples
                self.isWaveformLoading = false
            }
        }
    }

    private func seekPlayer(to time: Double) {
        let clamped = max(0, min(time, max(playerDurationSeconds, model.sourceDurationSeconds)))
        lastInteractiveSeekSeconds = -1
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playheadSeconds = clamped
        syncSharedPlayheadStateIfNeeded(clamped, force: true)
        syncVisualPlayheadImmediately(clamped)
        updateViewportForPlayhead(shouldFollow: !isViewportManuallyControlled || player.rate != 0)
    }

    private func seekPlayerInteractive(to time: Double) {
        let clamped = max(0, min(time, max(playerDurationSeconds, model.sourceDurationSeconds)))

        // Coalesce tiny drag deltas so scrubbing stays responsive without flooding seeks.
        if lastInteractiveSeekSeconds >= 0, abs(clamped - lastInteractiveSeekSeconds) < (1.0 / 120.0) {
            return
        }
        lastInteractiveSeekSeconds = clamped

        let tolerance = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
        playheadSeconds = clamped
        syncSharedPlayheadStateIfNeeded(clamped, force: true)
        syncVisualPlayheadImmediately(clamped)
        updateViewportForPlayhead(shouldFollow: false)
    }

    private func seekPlayerAnimatedFromKeyboard(to time: Double) {
        let clamped = max(0, min(time, max(playerDurationSeconds, model.sourceDurationSeconds)))
        let didChange = abs(clamped - playheadSeconds) > (1.0 / 240.0)
        seekPlayerAndFocusViewport(to: clamped, focusViewport: true)
        if didChange {
            springAnimateVisualPlayhead(to: clamped)
        } else {
            syncVisualPlayheadImmediately(clamped)
        }
    }

    private func seekPlayerAndFocusViewport(to time: Double, focusViewport: Bool = true) {
        let clamped = max(0, min(time, max(playerDurationSeconds, model.sourceDurationSeconds)))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playheadSeconds = clamped
        syncSharedPlayheadStateIfNeeded(clamped, force: true)

        guard focusViewport else { return }

        if timelineZoom > 1 {
            let currentStart = clampedViewportStart(viewportStartSeconds)
            let currentEnd = currentStart + zoomedWindowDuration
            if clamped < currentStart || clamped > currentEnd {
                animateViewportRecenter(to: clamped - (zoomedWindowDuration / 2.0))
            } else {
                viewportStartSeconds = currentStart
            }
            isViewportManuallyControlled = true
        } else {
            updateViewportForPlayhead(shouldFollow: true)
        }
    }

    private func jumpPlayback(by seconds: Double) {
        seekPlayer(to: playheadSeconds + seconds)
    }

    private func togglePlayback() {
        if player.rate != 0 {
            player.pause()
            syncSharedPlayheadStateIfNeeded(playheadSeconds, force: true, updateAlignment: true)
        } else {
            player.playImmediately(atRate: 1.0)
        }
    }

    private func nextShuttleRate(from currentAbsRate: Float) -> Float {
        let steps: [Float] = [1, 2, 4, 8]
        for step in steps where currentAbsRate < (step - 0.01) {
            return step
        }
        return steps.last ?? 8
    }

    private func shuttleForward() {
        let currentRate = player.rate
        let absRate = abs(currentRate)
        let nextRate: Float = currentRate > 0 ? nextShuttleRate(from: absRate) : 1.0
        player.playImmediately(atRate: nextRate)
    }

    private func shuttleBackward() {
        guard let item = player.currentItem else {
            jumpPlayback(by: -max(0.1, Double(model.jumpIntervalSeconds)))
            return
        }

        let supportsReverse = item.canPlayReverse || item.canPlayFastReverse
        guard supportsReverse else {
            // Fallback for assets that cannot reverse-play.
            jumpPlayback(by: -max(0.1, Double(model.jumpIntervalSeconds)))
            return
        }

        let currentRate = player.rate
        let absRate = abs(currentRate)
        let nextAbsRate: Float = currentRate < 0 ? nextShuttleRate(from: absRate) : 1.0
        player.playImmediately(atRate: -nextAbsRate)
    }

    private func pausePlayback() {
        if player.rate != 0 {
            player.pause()
        }
    }

    private func navigateToMarker(previous: Bool) {
        let epsilon = 1.0 / 240.0
        var points = model.captureTimelineMarkers.map(\.seconds)
        points.append(model.clipStartSeconds)
        points.append(model.clipEndSeconds)
        points.sort()

        var deduped: [Double] = []
        for point in points {
            if let last = deduped.last, abs(point - last) <= epsilon {
                continue
            }
            deduped.append(point)
        }
        guard !deduped.isEmpty else { return }

        let target: Double?
        if previous {
            target = deduped.last(where: { $0 < playheadSeconds - epsilon }) ?? deduped.first
        } else {
            target = deduped.first(where: { $0 > playheadSeconds + epsilon }) ?? deduped.last
        }

        guard let target else { return }
        let didChange = abs(target - playheadSeconds) > (1.0 / 240.0)
        // Keep viewport stable unless target is offscreen; then reveal it.
        seekPlayerAndFocusViewport(to: target, focusViewport: true)
        if didChange {
            springAnimateVisualPlayhead(to: target)
        } else {
            syncVisualPlayheadImmediately(target)
        }
        if model.nearestTimelineMarker(to: target, tolerance: 1.0 / 120.0) != nil {
            model.selectTimelineMarkerIfAligned(near: target, tolerance: 1.0 / 120.0)
            model.highlightedClipBoundary = nil
        } else {
            model.highlightedCaptureTimelineMarkerID = nil
            model.highlightBoundaryIfNeeded(near: target, clipStart: model.clipStartSeconds, clipEnd: model.clipEndSeconds)
        }
    }

    private var totalDurationSeconds: Double {
        max(0.001, max(playerDurationSeconds, model.sourceDurationSeconds))
    }

    private var zoomedWindowDuration: Double {
        max(0.25, totalDurationSeconds / max(1.0, timelineZoom))
    }

    private var deadZonePaddingSeconds: Double {
        // Keep 90% of the viewport as a no-pan zone to reduce disorienting jumps.
        max(0, zoomedWindowDuration * 0.05)
    }

    private var markerSnapToleranceSeconds: Double {
        let width = max(1, timelineInteractiveWidth)
        let snapDistanceInPixels: CGFloat = 16
        let secondsPerPixel = zoomedWindowDuration / Double(width)
        return min(0.75, max(1.0 / 30.0, secondsPerPixel * Double(snapDistanceInPixels)))
    }

    private func snappedMarkerTime(around seconds: Double) -> Double {
        guard let marker = model.nearestTimelineMarker(to: seconds, tolerance: markerSnapToleranceSeconds) else {
            return seconds
        }
        return marker.seconds
    }

    private func clampedViewportStart(_ start: Double) -> Double {
        let maxStart = max(0, totalDurationSeconds - zoomedWindowDuration)
        return min(max(0, start), maxStart)
    }

    private func animateViewportRecenter(to start: Double) {
        let clamped = clampedViewportStart(start)
        guard abs(clamped - viewportStartSeconds) > 0.0001 else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            viewportStartSeconds = clamped
        }
    }

    private func updateViewportForPlayhead(shouldFollow: Bool) {
        if timelineZoom <= 1 {
            if abs(viewportStartSeconds) > 0.000_001 {
                viewportStartSeconds = 0
            }
            if isViewportManuallyControlled {
                isViewportManuallyControlled = false
            }
            return
        }

        let window = zoomedWindowDuration
        var start = clampedViewportStart(viewportStartSeconds)
        guard shouldFollow else {
            if abs(viewportStartSeconds - start) > 0.000_001 {
                viewportStartSeconds = start
            }
            return
        }

        let end = start + window
        // Follow mode: keep playhead visible and recenter if it leaves the viewport.
        if playheadSeconds < start || playheadSeconds > end {
            animateViewportRecenter(to: playheadSeconds - (window / 2))
            return
        }

        let deadStart = start + deadZonePaddingSeconds
        let deadEnd = end - deadZonePaddingSeconds
        if playheadSeconds < deadStart {
            start = playheadSeconds - deadZonePaddingSeconds
        } else if playheadSeconds > deadEnd {
            start = playheadSeconds - (window - deadZonePaddingSeconds)
        }
        let clamped = clampedViewportStart(start)
        if abs(viewportStartSeconds - clamped) > 0.000_001 {
            viewportStartSeconds = clamped
        }
    }

    private func panViewport(byPoints points: CGFloat) {
        guard timelineZoom > 1 else { return }
        let width = max(1, timelineInteractiveWidth)
        let secondsPerPoint = zoomedWindowDuration / Double(width)
        // Natural-feeling pan: swipe left reveals later timeline content.
        let nextStart = clampedViewportStart(viewportStartSeconds - (Double(points) * secondsPerPoint))
        if abs(nextStart - viewportStartSeconds) < (zoomedWindowDuration / 2500.0) {
            return
        }
        viewportStartSeconds = nextStart
        isViewportManuallyControlled = true
    }

    private func autoPanViewportIfNeededForPlayheadDrag(x: CGFloat, width: CGFloat) -> Bool {
        guard timelineZoom > 1, width > 0 else { return false }
        let edgeZone = min(max(28.0, width * 0.08), 64.0)
        var panPoints: CGFloat = 0

        if x < edgeZone {
            let t = min(1.0, max(0.0, (edgeZone - x) / edgeZone))
            panPoints = 2.0 + (t * 22.0)
        } else if x > (width - edgeZone) {
            let t = min(1.0, max(0.0, (x - (width - edgeZone)) / edgeZone))
            panPoints = -(2.0 + (t * 22.0))
        }

        if abs(panPoints) >= 0.5 {
            let previous = viewportStartSeconds
            panViewport(byPoints: panPoints)
            return abs(viewportStartSeconds - previous) > 0.00001
        }
        return false
    }

    private func timeForPlayheadDragLocation(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return playheadSeconds }
        let ratio = min(max(0, x / width), 1.0)
        let duration = max(0.0001, visibleEndSeconds - visibleStartSeconds)
        return min(totalDurationSeconds, max(0, visibleStartSeconds + (Double(ratio) * duration)))
    }

    private func startPlayheadDragAutoPanLoopIfNeeded() {
        guard playheadDragAutoPanTask == nil else { return }
        playheadDragAutoPanTask = Task { @MainActor in
            while !Task.isCancelled && isPlayheadDragActive {
                guard let x = playheadDragLocationX, playheadDragWidth > 0 else {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    continue
                }
                if autoPanViewportIfNeededForPlayheadDrag(x: x, width: playheadDragWidth) {
                    seekPlayerInteractive(to: timeForPlayheadDragLocation(x: x, width: playheadDragWidth))
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func stopPlayheadDragAutoPanLoop() {
        playheadDragAutoPanTask?.cancel()
        playheadDragAutoPanTask = nil
    }

    private func updatePlayheadDragLocation(_ x: CGFloat, width: CGFloat) {
        playheadDragLocationX = x
        playheadDragWidth = width
    }

    private func setPlayheadDragActive(_ active: Bool) {
        isPlayheadDragActive = active
        if active {
            startPlayheadDragAutoPanLoopIfNeeded()
        } else {
            stopPlayheadDragAutoPanLoop()
            playheadDragLocationX = nil
            playheadDragWidth = 0
        }
    }

    private func adjustTimelineZoom(by deltaSteps: Int) {
        let nextIndex = timelineZoomIndex + deltaSteps
        guard nextIndex >= 0, nextIndex < allowedTimelineZoomLevels.count else { return }
        setTimelineZoomIndex(nextIndex)
    }

    private func resetTimelineZoom() {
        guard timelineZoom != allowedTimelineZoomLevels[0] else { return }
        setTimelineZoomIndex(0)
    }

    private func panViewportByKeyboard(towardLaterTime: Bool) {
        guard timelineZoom > 1 else { return }
        let step = max(0.05, zoomedWindowDuration * 0.10)
        let delta = towardLaterTime ? step : -step
        let nextStart = clampedViewportStart(viewportStartSeconds + delta)
        guard abs(nextStart - viewportStartSeconds) > 0.000001 else { return }

        keyboardPanTask?.cancel()
        let fromStart = viewportStartSeconds
        let toStart = nextStart
        keyboardPanTask = Task { @MainActor in
            let animationDuration = 0.16
            let startTime = CACurrentMediaTime()
            while !Task.isCancelled {
                let elapsed = CACurrentMediaTime() - startTime
                let t = min(1.0, max(0.0, elapsed / animationDuration))
                let eased = 1.0 - pow(1.0 - t, 3.0) // cubic ease-out
                viewportStartSeconds = fromStart + ((toStart - fromStart) * eased)
                if t >= 1.0 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            viewportStartSeconds = toStart
            keyboardPanTask = nil
        }
        isViewportManuallyControlled = true
    }

    private func copyPlayheadTimecode() {
        let timecode = formatSeconds(playheadSeconds)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(timecode, forType: .string)
        withAnimation(.easeOut(duration: 0.12)) {
            playheadCopyFlash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            withAnimation(.easeOut(duration: 0.18)) {
                playheadCopyFlash = false
            }
        }
        model.uiMessage = "Copied playhead timecode: \(timecode)"
    }

    private func syncSharedPlayheadStateIfNeeded(_ seconds: Double, force: Bool, updateAlignment: Bool = true) {
        let now = CACurrentMediaTime()
        let syncInterval = 1.0 / 8.0
        guard force || (now - lastSharedPlayheadSyncTimestamp) >= syncInterval else { return }
        if abs(model.clipPlayheadSeconds - seconds) > (1.0 / 240.0) {
            model.clipPlayheadSeconds = seconds
        }
        if updateAlignment {
            model.selectTimelineMarkerIfAligned(near: seconds)
        }
        lastSharedPlayheadSyncTimestamp = now
    }

    private var visibleStartSeconds: Double {
        if timelineZoom <= 1 {
            return 0
        }
        return clampedViewportStart(viewportStartSeconds)
    }

    private var visibleEndSeconds: Double {
        min(totalDurationSeconds, visibleStartSeconds + zoomedWindowDuration)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard clipWindow?.isKeyWindow == true else { return event }

            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let rawChars = event.characters ?? ""
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasDisallowedModifier = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)

            if flags.contains(.command) && flags.contains(.option) && !flags.contains(.control) && !flags.contains(.shift) {
                if chars == "s",
                   model.sourceURL != nil,
                   model.hasVideoTrack {
                    model.captureFrame(at: effectivePlayheadSeconds())
                    return nil
                }
            }

            if NSApp.keyWindow?.firstResponder is NSTextView {
                return event
            }

            if flags.isDisjoint(with: [.command, .option, .control, .shift]) {
                if rawChars == " " {
                    togglePlayback()
                    return nil
                }
                if chars == "k" {
                    pausePlayback()
                    return nil
                }
                if chars == "l" {
                    shuttleForward()
                    return nil
                }
                if chars == "j" {
                    shuttleBackward()
                    return nil
                }
            }

            if flags.contains(.command) && !flags.contains(.option) && !flags.contains(.control) {
                if event.specialKey == .leftArrow {
                    seekPlayerAnimatedFromKeyboard(to: 0)
                    return nil
                }
                if event.specialKey == .rightArrow {
                    seekPlayerAnimatedFromKeyboard(to: totalDurationSeconds)
                    return nil
                }
                if chars == "=" || chars == "+" {
                    adjustTimelineZoom(by: 1)
                    return nil
                }
                if chars == "-" || chars == "_" {
                    adjustTimelineZoom(by: -1)
                    return nil
                }
                if chars == "0" {
                    resetTimelineZoom()
                    return nil
                }
            }

            if flags.contains(.option) && !flags.contains(.command) && !flags.contains(.control) && !flags.contains(.shift) {
                if event.specialKey == .leftArrow {
                    panViewportByKeyboard(towardLaterTime: false)
                    return nil
                }
                if event.specialKey == .rightArrow {
                    panViewportByKeyboard(towardLaterTime: true)
                    return nil
                }
            }

            if flags.contains(.option) && flags.contains(.shift) && !flags.contains(.command) && !flags.contains(.control) {
                let fps = max(1.0, model.sourceInfo?.frameRate ?? 30.0)
                let hundredFrames = 100.0 / fps
                if event.specialKey == .leftArrow {
                    seekPlayerAnimatedFromKeyboard(to: playheadSeconds - hundredFrames)
                    return nil
                }
                if event.specialKey == .rightArrow {
                    seekPlayerAnimatedFromKeyboard(to: playheadSeconds + hundredFrames)
                    return nil
                }
            }

            if !hasDisallowedModifier && !flags.contains(.shift) {
                if event.specialKey == .home {
                    seekPlayerAnimatedFromKeyboard(to: 0)
                    return nil
                }
                if event.specialKey == .end {
                    seekPlayerAnimatedFromKeyboard(to: totalDurationSeconds)
                    return nil
                }
                let fps = max(1.0, model.sourceInfo?.frameRate ?? 30.0)
                let oneFrame = 1.0 / fps
                if event.specialKey == .leftArrow {
                    seekPlayer(to: playheadSeconds - oneFrame)
                    return nil
                }
                if event.specialKey == .rightArrow {
                    seekPlayer(to: playheadSeconds + oneFrame)
                    return nil
                }
                if event.specialKey == .upArrow {
                    navigateToMarker(previous: true)
                    return nil
                }
                if event.specialKey == .downArrow {
                    navigateToMarker(previous: false)
                    return nil
                }
                if event.keyCode == 51 || event.keyCode == 117 {
                    if model.removeHighlightedTimelineMarker(undoManager: undoManager) {
                        model.uiMessage = "Marker deleted"
                    }
                    return nil
                }
            }

            if flags.isDisjoint(with: [.command, .option, .control]) && !flags.contains(.shift) {
                if chars == "i" {
                    model.setClipStart(effectivePlayheadSeconds(), undoManager: undoManager)
                    return nil
                }
                if chars == "o" {
                    model.setClipEnd(effectivePlayheadSeconds(), undoManager: undoManager)
                    return nil
                }
                if chars == "x" {
                    model.resetClipRange(undoManager: undoManager)
                    seekPlayer(to: model.clipStartSeconds)
                    return nil
                }
                if chars == "m" {
                    model.addTimelineMarker(at: effectivePlayheadSeconds(), undoManager: undoManager)
                    return nil
                }
            }

            let hasShift = flags.contains(.shift)
            guard hasShift && !hasDisallowedModifier else { return event }

            let fps = max(1.0, model.sourceInfo?.frameRate ?? 30.0)
            let tenFrames = 10.0 / fps

            if event.specialKey == .leftArrow {
                seekPlayerAnimatedFromKeyboard(to: playheadSeconds - tenFrames)
                return nil
            }

            if event.specialKey == .rightArrow {
                seekPlayerAnimatedFromKeyboard(to: playheadSeconds + tenFrames)
                return nil
            }

            return event
        }
    }

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            guard clipWindow?.isKeyWindow == true else { return event }
            guard isTimelineHovered, timelineZoom > 1 else { return event }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let panPoints: CGFloat
            if abs(dx) >= 0.1 {
                panPoints = dx
            } else if event.modifierFlags.contains(.shift) && abs(dy) >= 0.1 {
                panPoints = dy
            } else {
                return event
            }

            // Ignore tiny jitter deltas to reduce needless redraw churn.
            if abs(panPoints) < 0.45 {
                return nil
            }

            panViewport(byPoints: panPoints)
            return nil
        }
    }

    private func installFlagsMonitor() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            guard clipWindow?.isKeyWindow == true else { return event }
            isOptionKeyPressed = event.modifierFlags.contains(.option)
            return event
        }
    }

    private func installMouseDownMonitor() {
        guard mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard clipWindow?.isKeyWindow == true else { return event }
            guard let window = NSApp.keyWindow else { return event }
            guard window.firstResponder is NSTextView else { return event }

            let clickPoint = window.contentView?.convert(event.locationInWindow, from: nil) ?? .zero
            let hitView = window.contentView?.hitTest(clickPoint)
            if isTextInputView(hitView) {
                return event
            }

            dismissTimecodeFieldFocus()
            return event
        }
    }

    private func updateTimelineCursor() {
        guard timelineZoom > 1, isWaveformHovered, isMiddleMousePanning else {
            NSCursor.arrow.set()
            return
        }
        NSCursor.closedHand.set()
    }

    private func installMiddleMousePanMonitor() {
        guard middleMousePanMonitor == nil else { return }
        middleMousePanMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseDragged, .otherMouseUp]) { event in
            guard clipWindow?.isKeyWindow == true else { return event }
            guard event.buttonNumber == 2 else { return event }

            switch event.type {
            case .otherMouseDown:
                guard isWaveformHovered, timelineZoom > 1 else { return event }
                isMiddleMousePanning = true
                middleMousePanLastWindowX = event.locationInWindow.x
                updateTimelineCursor()
                return nil
            case .otherMouseDragged:
                guard isMiddleMousePanning else { return event }
                let currentX = event.locationInWindow.x
                let lastX = middleMousePanLastWindowX ?? currentX
                let deltaX = currentX - lastX
                middleMousePanLastWindowX = currentX
                panViewport(byPoints: deltaX)
                return nil
            case .otherMouseUp:
                guard isMiddleMousePanning else { return event }
                isMiddleMousePanning = false
                middleMousePanLastWindowX = nil
                updateTimelineCursor()
                return nil
            default:
                return event
            }
        }
    }

    private func isTextInputView(_ view: NSView?) -> Bool {
        var current = view
        while let v = current {
            if v is NSTextView || v is NSTextField {
                return true
            }
            current = v.superview
        }
        return false
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
        if let middleMousePanMonitor {
            NSEvent.removeMonitor(middleMousePanMonitor)
            self.middleMousePanMonitor = nil
        }
    }

    private func dismissTimecodeFieldFocus() {
        model.commitClipStartText(undoManager: undoManager)
        model.commitClipEndText(undoManager: undoManager)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var playerMinHeight: CGFloat {
        isCompactLayout ? 140 : 220
    }

    private var playerHardMaxHeight: CGFloat {
        isCompactLayout ? 340 : 720
    }

    private var playerMaxHeight: CGFloat {
        guard clipContentHeight > 0 else {
            return playerHardMaxHeight
        }
        let ratioCap = clipContentHeight * (isCompactLayout ? 0.52 : 0.62)
        return min(playerHardMaxHeight, max(playerMinHeight + 20, ratioCap))
    }

    private var playerDefaultHeight: CGFloat {
        let fallback: CGFloat = isCompactLayout ? 185 : 300
        guard clipContentHeight > 0 else {
            return fallback
        }

        // Keep timeline/waveform visible at default sizes while still allowing
        // a larger player in taller windows.
        let reserveForControls = isCompactLayout ? CGFloat(320) : CGFloat(390)
        let byReserve = clipContentHeight - reserveForControls
        let byRatio = clipContentHeight * (isCompactLayout ? 0.30 : 0.40)
        let preferred = min(byReserve, byRatio)
        return clampedPlayerHeight(max(fallback, preferred))
    }

    private func clampedPlayerHeight(_ value: CGFloat) -> CGFloat {
        min(max(value, playerMinHeight), playerMaxHeight)
    }

    private var currentPlayerHeight: CGFloat {
        if let livePlayerHeight {
            return clampedPlayerHeight(livePlayerHeight)
        }
        // `storedPlayerHeight == 0` is auto-height mode.
        let raw = storedPlayerHeight > 0 ? CGFloat(storedPlayerHeight) : playerDefaultHeight
        return clampedPlayerHeight(raw)
    }

    private var clipPlayerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            InlinePlayerView(player: player)
                .frame(height: currentPlayerHeight)
                .transaction { transaction in
                    transaction.animation = nil
                }
                .clipShape(RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous))
                .onTapGesture {
                    dismissTimecodeFieldFocus()
                }

            HStack {
                Spacer()
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 36, height: 4)
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                    .padding(.vertical, 2)
                Spacer()
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.set()
                } else if !isMiddleMousePanning {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if playerResizeStartHeight == nil {
                            let base = storedPlayerHeight > 0 ? CGFloat(storedPlayerHeight) : playerDefaultHeight
                            playerResizeStartHeight = clampedPlayerHeight(base)
                            playerResizeStartGlobalY = value.startLocation.y
                        }
                        let base = playerResizeStartHeight ?? currentPlayerHeight
                        let startY = playerResizeStartGlobalY ?? value.startLocation.y
                        let deltaY = value.location.y - startY
                        livePlayerHeight = clampedPlayerHeight(base + deltaY)
                    }
                    .onEnded { _ in
                        if let livePlayerHeight {
                            storedPlayerHeight = Double(clampedPlayerHeight(livePlayerHeight))
                        }
                        livePlayerHeight = nil
                        playerResizeStartHeight = nil
                        playerResizeStartGlobalY = nil
                    }
            )
            .onTapGesture(count: 2) {
                let current = currentPlayerHeight
                let defaultHeight = playerDefaultHeight
                let maxHeight = playerMaxHeight
                let tolerance: CGFloat = 2.0
                let target = abs(current - defaultHeight) <= tolerance ? maxHeight : defaultHeight
                livePlayerHeight = nil
                withAnimation(.easeOut(duration: 0.18)) {
                    storedPlayerHeight = Double(target)
                }
            }
            .accessibilityLabel("Resize player height")
            .help("Drag to resize player height. Double-click to toggle default/max height.")
        }
        .onChange(of: isCompactLayout) { _ in
            storedPlayerHeight = Double(clampedPlayerHeight(currentPlayerHeight))
        }
    }

    private func resetPlayerHeightToDefaultIfNeeded() {
        if storedPlayerHeight > 0 {
            storedPlayerHeight = Double(clampedPlayerHeight(CGFloat(storedPlayerHeight)))
        }
    }

    private var timelineControlsSection: some View {
        ClipTimelineControlsPanel(
            reduceTransparency: reduceTransparency,
            allowedTimelineZoomLevels: allowedTimelineZoomLevels,
            timelineZoomIndex: timelineZoomIndex,
            setTimelineZoomIndex: setTimelineZoomIndex,
            timelineZoom: timelineZoom,
            totalDurationSeconds: totalDurationSeconds,
            visibleStartSeconds: visibleStartSeconds,
            visibleEndSeconds: visibleEndSeconds,
            playheadSeconds: playheadSeconds,
            clipStartSeconds: model.clipStartSeconds,
            clipEndSeconds: model.clipEndSeconds,
            captureMarkers: model.captureTimelineMarkers
        ) { newStart in
            viewportStartSeconds = clampedViewportStart(newStart)
            isViewportManuallyControlled = true
        } content: {
            selectionSection
        }
    }

    private var selectionSection: some View {
        ClipSelectionPanel(
            player: player,
            sourceSessionID: model.sourceSessionID,
            clipStartSeconds: model.clipStartSeconds,
            clipEndSeconds: model.clipEndSeconds,
            clipDurationSeconds: model.clipDurationSeconds,
            hasVideoTrack: model.hasVideoTrack,
            clipStartText: $model.clipStartText,
            clipEndText: $model.clipEndText,
            onCommitClipStartText: { model.commitClipStartText(undoManager: undoManager) },
            onCommitClipEndText: { model.commitClipEndText(undoManager: undoManager) },
            isCompactLayout: isCompactLayout,
            reduceTransparency: reduceTransparency,
            isWaveformLoading: isWaveformLoading,
            waveformSamples: waveformSamples,
            allowedTimelineZoomLevels: allowedTimelineZoomLevels,
            timelineZoom: timelineZoom,
            totalDurationSeconds: totalDurationSeconds,
            visibleStartSeconds: visibleStartSeconds,
            visibleEndSeconds: visibleEndSeconds,
            playheadVisualSeconds: playheadVisualSeconds,
            playheadJumpFromSeconds: playheadJumpFromSeconds,
            playheadJumpAnimationToken: playheadJumpAnimationToken,
            playheadSeconds: playheadSeconds,
            playheadCopyFlash: playheadCopyFlash,
            isTimelineHovered: isTimelineHovered,
            captureMarkers: model.captureTimelineMarkers,
            highlightedMarkerID: model.highlightedCaptureTimelineMarkerID,
            highlightedClipBoundary: model.highlightedClipBoundary,
            captureFrameFlashToken: model.captureFrameFlashToken,
            quickExportFlashToken: model.quickExportFlashToken,
            onTimelineWidthChanged: { timelineInteractiveWidth = $0 },
            onSeek: { seconds, shouldSnapToMarker in
                let target = shouldSnapToMarker ? snappedMarkerTime(around: seconds) : seconds
                if shouldSnapToMarker {
                    seekPlayer(to: target)
                } else {
                    seekPlayerInteractive(to: target)
                }
            },
            onPlayheadDragEdgePan: { x, width in
                updatePlayheadDragLocation(x, width: width)
            },
            onPlayheadDragStateChanged: { isActive in
                setPlayheadDragActive(isActive)
            },
            onSetStart: { model.setClipStart($0, undoManager: undoManager) },
            onSetEnd: { model.setClipEnd($0, undoManager: undoManager) },
            onWaveformHoverChanged: { hovering in
                isWaveformHovered = hovering
                if !hovering {
                    timelinePointerSeconds = nil
                }
                if !isMiddleMousePanning {
                    updateTimelineCursor()
                }
            },
            onWaveformPointerTimeChanged: { timelinePointerSeconds = $0 },
            onTimelineHoverChanged: { hovering in
                isTimelineHovered = hovering
                if !isMiddleMousePanning {
                    NSCursor.arrow.set()
                }
            },
            onCopyPlayheadTimecode: copyPlayheadTimecode,
            onJumpToStart: {
                seekPlayer(to: model.clipStartSeconds)
                springAnimateVisualPlayhead(to: model.clipStartSeconds)
            },
            onJumpToEnd: {
                seekPlayer(to: model.clipEndSeconds)
                springAnimateVisualPlayhead(to: model.clipEndSeconds)
            },
            onCaptureFrame: {
                model.captureFrame(at: playheadSeconds)
            }
        )
        .equatable()
    }

    private var outputSection: some View {
        ClipOutputPanel(
            model: model,
            reduceTransparency: reduceTransparency,
            isOptionKeyPressed: isOptionKeyPressed,
            fastClipFormats: fastClipFormats,
            advancedClipFormats: advancedClipFormats,
            onStartExport: { quickExport in
                model.commitClipStartText(undoManager: undoManager)
                model.commitClipEndText(undoManager: undoManager)
                model.startClipExport(skipSaveDialog: quickExport)
            },
            onEnqueueExport: { quickExport in
                model.commitClipStartText(undoManager: undoManager)
                model.commitClipEndText(undoManager: undoManager)
                model.enqueueCurrentClipExport(skipSaveDialog: quickExport)
            }
        )
    }

    private var clipBaseContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.sourceURL != nil {
                clipPlayerSection
                timelineControlsSection
                outputSection
                Spacer()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissTimecodeFieldFocus()
                    }
            } else {
                Spacer(minLength: 0)
                emptySourceImportView
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        clipContentHeight = geo.size.height
                    }
                    .onChange(of: geo.size.height) { newHeight in
                        clipContentHeight = newHeight
                    }
            }
        )
        .sheet(isPresented: $model.isURLImportSheetPresented) {
            urlImportSheetView
        }
    }

    private var emptySourceImportView: some View {
        VStack(alignment: .center, spacing: 22) {
            Text("Open Media")
                .font(.system(size: 32, weight: .semibold))

            VStack(spacing: 10) {
                Image(systemName: "film")
                    .font(.system(size: 58, weight: .regular))
                    .foregroundStyle(isEmptyDropTargeted ? Color.accentColor : Color.secondary)

                Text("Drag a video or audio file here")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.secondary)

                Button("Choose File…") {
                    model.chooseSource()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, minHeight: 360)
            .background(
                RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
                    .fill(
                        adaptiveContainerFill(
                            material: .thinMaterial,
                            fallback: Color(nsColor: .controlBackgroundColor),
                            reduceTransparency: reduceTransparency
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
                    .stroke(
                        isEmptyDropTargeted ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.24),
                        style: StrokeStyle(lineWidth: isEmptyDropTargeted ? 2.4 : 1.6, dash: [8, 6])
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
                    .stroke(isEmptyDropTargeted ? Color.accentColor.opacity(0.2) : Color.clear, lineWidth: 6)
            )
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isEmptyDropTargeted) { providers in
                model.handleDrop(providers: providers)
            }

            HStack(spacing: 12) {
                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(height: 1)
                    .frame(maxWidth: 260)
                Text("or")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.tertiary)
                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(height: 1)
                    .frame(maxWidth: 260)
            }
            .padding(.vertical, 2)

            VStack(alignment: .center, spacing: 10) {
                Text("Download from URL")
                    .font(.system(size: 26, weight: .semibold))

                HStack(spacing: 8) {
                    TextField("https://…", text: $emptyStateURLText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .font(.system(size: 18))
                        .frame(minHeight: 44)

                    Button("Download") {
                        let trimmed = emptyStateURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        model.startURLImport(
                            urlText: trimmed,
                            preset: model.urlDownloadPreset,
                            saveMode: model.urlDownloadSaveLocationMode,
                            customFolderPath: model.customURLDownloadDirectoryPath
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .controlSize(.large)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(minHeight: 44)
                    .disabled(emptyStateURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .frame(maxWidth: 920)

                if !model.ytDLPAvailable {
                    Text("yt-dlp is required for URL downloads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .disabled(!model.ytDLPAvailable || !model.canRequestURLDownload)
        }
        .frame(maxWidth: 980)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var clipboardURLString: String? {
        guard let value = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return value
        }
        return nil
    }

    private func prepareURLImportSheetDefaults() {
        importURLText = ""
        importURLPreset = model.urlDownloadPreset
        importURLSaveMode = model.urlDownloadSaveLocationMode
        importCustomFolderPath = model.customURLDownloadDirectoryPath
        showURLImportAdvancedOptions = false
    }

    private func submitURLImportSheet() {
        let trimmed = importURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.isURLImportSheetPresented = false
        model.startURLImport(
            urlText: trimmed,
            preset: importURLPreset,
            saveMode: importURLSaveMode,
            customFolderPath: importCustomFolderPath
        )
    }

    private var importPresetHelpText: String? {
        switch importURLPreset {
        case .compatibleBest:
            return "Optimized for immediate playback in In/Out."
        case .bestAnyToMP4:
            return "Downloads highest available quality, then transcodes to MP4 for compatibility."
        case .audioOnly:
            return "Extracts audio and saves as MP3."
        case .compatible1080:
            return "Limits to 1080p-compatible formats."
        case .compatible720:
            return "Limits to 720p-compatible formats."
        }
    }

    private var urlImportSheetView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download from URL")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                Text("URL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("https://example.com/video", text: $importURLText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isImportURLFieldFocused)
                        .onSubmit {
                            submitURLImportSheet()
                        }
                    if let clipboardURLString {
                        Button("Paste URL") {
                            importURLText = clipboardURLString
                            isImportURLFieldFocused = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showURLImportAdvancedOptions ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Text("More Options")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showURLImportAdvancedOptions.toggle()
                    }
                }

                if showURLImportAdvancedOptions {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Quality")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(URLDownloadPreset.allCases) { preset in
                                Button {
                                    importURLPreset = preset
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: importURLPreset == preset ? "largecircle.fill.circle" : "circle")
                                            .font(.system(size: 13, weight: .regular))
                                            .foregroundStyle(importURLPreset == preset ? Color.accentColor : .secondary)
                                        Text(preset.rawValue)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        if preset == .compatibleBest {
                                            Text("Recommended")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(Color.accentColor.opacity(0.16), in: Capsule())
                                                .foregroundStyle(Color.accentColor)
                                        }
                                        if preset == .bestAnyToMP4 {
                                            Text("Slow")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(Color.red.opacity(0.16), in: Capsule())
                                                .foregroundStyle(.red)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if let importPresetHelpText {
                            Text(importPresetHelpText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                            .frame(height: 8)

                        Text("Save Location")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("Save location", selection: $importURLSaveMode) {
                            ForEach(URLDownloadSaveLocationMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if importURLSaveMode == .customFolder {
                            HStack(spacing: 8) {
                                Text(importCustomFolderPath.isEmpty ? "No custom folder selected" : importCustomFolderPath)
                                    .font(.caption)
                                    .foregroundStyle(importCustomFolderPath.isEmpty ? .secondary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button("Choose…") {
                                    model.chooseCustomURLDownloadDirectory()
                                    importCustomFolderPath = model.customURLDownloadDirectoryPath
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.leading, 14)
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showURLImportAdvancedOptions)
            .animation(.easeInOut(duration: 0.15), value: importURLPreset)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.isURLImportSheetPresented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Button("Download") {
                    submitURLImportSheet()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(importURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if importURLText.isEmpty {
                prepareURLImportSheetDefaults()
            }
            DispatchQueue.main.async {
                isImportURLFieldFocused = true
            }
        }
    }

    private func withLifecycleHandlers<V: View>(_ view: V) -> some View {
        let step1 = view.onAppear {
            resetPlayerHeightToDefaultIfNeeded()
            loadPlayerItem()
            installPlayerTimeObserverIfNeeded()
            installKeyMonitor()
            installFlagsMonitor()
            installScrollMonitor()
            installMouseDownMonitor()
            installMiddleMousePanMonitor()
        }

        let step2 = step1.onChange(of: model.sourceURL?.path) { _ in
            loadPlayerItem()
        }

        let step3 = step2.onChange(of: model.clipEncodingMode) { mode in
            if !model.hasVideoTrack && mode != .audioOnly {
                model.clipEncodingMode = .audioOnly
                return
            }
            if mode == .fast && !model.selectedClipFormat.supportsPassthrough {
                model.selectedClipFormat = .mp4
            }
        }

        let step4 = step3
            .onChange(of: model.selectedClipFormat) { format in
                if format == .webm {
                    model.clipAdvancedVideoCodec = .h264
                }
            }

        let step5 = step4
            .onReceive(NotificationCenter.default.publisher(for: .clipSetStartAtPlayhead, object: model)) { _ in
                model.setClipStart(effectivePlayheadSeconds(), undoManager: undoManager)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipSetEndAtPlayhead, object: model)) { _ in
                model.setClipEnd(effectivePlayheadSeconds(), undoManager: undoManager)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipClearRange, object: model)) { _ in
                model.resetClipRange(undoManager: undoManager)
                seekPlayer(to: model.clipStartSeconds)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipAddMarkerAtPlayhead, object: model)) { _ in
                model.addTimelineMarker(at: effectivePlayheadSeconds(), undoManager: undoManager)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipJumpToStart, object: model)) { _ in
                navigateToMarker(previous: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipJumpToEnd, object: model)) { _ in
                navigateToMarker(previous: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipCaptureFrame, object: model)) { _ in
                model.captureFrame(at: effectivePlayheadSeconds())
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipTimelineZoomIn, object: model)) { _ in
                adjustTimelineZoom(by: 1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipTimelineZoomOut, object: model)) { _ in
                adjustTimelineZoom(by: -1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipTimelineZoomReset, object: model)) { _ in
                resetTimelineZoom()
            }

        return step5.onDisappear {
            waveformTask?.cancel()
            keyboardPanTask?.cancel()
            keyboardPanTask = nil
            syncSharedPlayheadStateIfNeeded(playheadSeconds, force: true, updateAlignment: true)
            removeKeyMonitor()
            removePlayerTimeObserver()
            isOptionKeyPressed = false
            isMiddleMousePanning = false
            middleMousePanLastWindowX = nil
            isWaveformHovered = false
            stopPlayheadDragAutoPanLoop()
            NSCursor.arrow.set()
            player.pause()
        }
    }

    var body: some View {
        withLifecycleHandlers(clipBaseContent)
            .background(
                WindowAccessor { window in
                    clipWindow = window
                }
            )
    }
}

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
                    }
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
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let isFirstDragEvent = !didStartPlayheadDrag
                        let shouldSnapToMarker = isFirstDragEvent
                        if !didStartPlayheadDrag {
                            didStartPlayheadDrag = true
                            onPlayheadDragStateChanged(true)
                        }
                        if let snapLock = markerSnapLockSeconds {
                            // Keep click-to-snap stable across micro movement/noise.
                            if abs(value.translation.width) <= 3 && abs(value.translation.height) <= 3 {
                                onSeek(snapLock, true)
                                return
                            }
                            markerSnapLockSeconds = nil
                        }
                        onPlayheadDragEdgePan(value.location.x, width)
                        if isFirstDragEvent,
                           let markerSeconds = markerNearX(value.location.x, width: width) {
                            markerSnapLockSeconds = markerSeconds
                            onSeek(markerSeconds, true)
                            return
                        }
                        onSeek(
                            timeValue(for: value.location.x, width: width, windowStart: visibleStartSeconds, windowEnd: visibleEndSeconds),
                            shouldSnapToMarker
                        )
                    }
                    .onEnded { _ in
                        didStartPlayheadDrag = false
                        markerSnapLockSeconds = nil
                        onPlayheadDragStateChanged(false)
                    }
            , including: .gesture)
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
    var playheadDisplayWidth: CGFloat = 2
    private var livePlaybackTimer: Timer?
    var onMarkerSeek: ((Double) -> Void)?
    var markerHotspots: [MarkerHotspot] = []
    var markerLayersByID: [UUID: CALayer] = [:]
    private var trackingAreaRef: NSTrackingArea?
    private var markerCursorActive = false
    private let markerHitTolerance: CGFloat = 12
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
        // Marker click-to-seek is handled in the SwiftUI gesture path so
        // hover/click use one resolver and avoid double-seek race conditions.
        super.mouseDown(with: event)
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
        guard let player, player.rate != 0 else {
            stopLivePlaybackTimer()
            return
        }
        let current = CMTimeGetSeconds(player.currentTime())
        guard current.isFinite else { return }
        let duration = max(0.0001, visibleEndSeconds - visibleStartSeconds)
        let local = (current - visibleStartSeconds) / duration
        let x = CGFloat(local) * bounds.width
        let snappedX = x.rounded()
        let targetFrame = CGRect(
            x: snappedX - (playheadDisplayWidth / 2.0),
            y: -4,
            width: playheadDisplayWidth,
            height: bounds.height + 8
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadLayer.frame = targetFrame
        let visible = snappedX >= -6 && snappedX <= (bounds.width + 6)
        playheadLayer.opacity = visible ? 1.0 : 0.0
        CATransaction.commit()
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
        return view
    }

    func updateNSView(_ nsView: WaveformRasterHostView, context: Context) {
        nsView.onMarkerSeek = onMarkerSeek
        nsView.player = player
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

        let playheadX = snapToPixel(xPosition(for: playheadSeconds))
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
