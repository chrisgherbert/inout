import AppKit
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
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
    @State private var dragVisualPlayheadSeconds: Double?
    @State private var lastInteractiveSeekCommitTimestamp: CFTimeInterval = 0
    @State private var lastInteractiveReadoutSyncTimestamp: CFTimeInterval = 0
    @State private var lastSharedPlayheadSyncTimestamp: CFTimeInterval = 0
    @State private var timelinePointerSeconds: Double?
    @State private var clipWindow: NSWindow?
    @State private var clipContentHeight: CGFloat = 0
    @State private var playerTimeObserverToken: Any?
    @State private var lastPlaybackUIUpdateTimestamp: CFTimeInterval = 0
    @State private var lastPlaybackFollowUpdateTimestamp: CFTimeInterval = 0
    @SceneStorage("clip.playerHeight") private var storedPlayerHeight: Double = 0
    @SceneStorage("clip.transcriptSidebarWidth") private var storedTranscriptSidebarWidth: Double = 440
    @SceneStorage("clip.transcriptSidebarVisible") private var storedTranscriptSidebarVisible = true
    @State private var playerResizeStartHeight: CGFloat?
    @State private var playerResizeStartGlobalY: CGFloat?
    @State private var livePlayerHeight: CGFloat?
    @State private var transcriptSidebarResizeStartWidth: CGFloat?
    @State private var transcriptSidebarResizeStartGlobalX: CGFloat?
    @State private var liveTranscriptSidebarWidth: CGFloat?
    @State private var clipTranscriptSidebarTimeSeconds: Double = 0
    @State private var clipTranscriptSearchFocusToken: Int = 0
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
        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        playerTimeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let current = CMTimeGetSeconds(time)
            if current.isFinite {
                let newPlayhead = max(0, current)
                let didMove = abs(newPlayhead - playheadSeconds) > (1.0 / 240.0)

                if didMove {
                    let now = CACurrentMediaTime()
                    let isPlaying = player.rate != 0
                    let uiUpdateInterval = isPlaying ? (1.0 / 30.0) : (1.0 / 60.0)
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
                        if (now - lastPlaybackFollowUpdateTimestamp) >= (1.0 / 20.0) {
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
        dragVisualPlayheadSeconds = nil
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playheadSeconds = clamped
        syncSharedPlayheadStateIfNeeded(clamped, force: true)
        syncVisualPlayheadImmediately(clamped)
        updateViewportForPlayhead(shouldFollow: !isViewportManuallyControlled || player.rate != 0)
    }

    private func commitInteractiveSeek(to time: Double) {
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
        playheadVisualSeconds = clamped
        updateViewportForPlayhead(shouldFollow: false)
    }

    private func seekPlayerInteractive(to time: Double, forceCommit: Bool = false) {
        let clamped = max(0, min(time, max(playerDurationSeconds, model.sourceDurationSeconds)))

        let now = CACurrentMediaTime()
        let readoutInterval = 1.0 / 30.0
        if forceCommit || (now - lastInteractiveReadoutSyncTimestamp) >= readoutInterval {
            dragVisualPlayheadSeconds = clamped
            playheadVisualSeconds = clamped
            lastInteractiveReadoutSyncTimestamp = now
        }

        let commitInterval = 1.0 / 30.0
        guard forceCommit || (now - lastInteractiveSeekCommitTimestamp) >= commitInterval else { return }
        lastInteractiveSeekCommitTimestamp = now
        commitInteractiveSeek(to: clamped)
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
            lastInteractiveSeekCommitTimestamp = 0
            lastInteractiveReadoutSyncTimestamp = 0
            startPlayheadDragAutoPanLoopIfNeeded()
        } else {
            stopPlayheadDragAutoPanLoop()
            if let x = playheadDragLocationX, playheadDragWidth > 0 {
                seekPlayerInteractive(to: timeForPlayheadDragLocation(x: x, width: playheadDragWidth), forceCommit: true)
            }
            if let dragVisualPlayheadSeconds {
                playheadSeconds = dragVisualPlayheadSeconds
                syncSharedPlayheadStateIfNeeded(dragVisualPlayheadSeconds, force: true)
                syncVisualPlayheadImmediately(dragVisualPlayheadSeconds)
            }
            dragVisualPlayheadSeconds = nil
            lastInteractiveSeekSeconds = -1
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
        let syncInterval = 1.0 / 20.0
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
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let acceleratedModifier = flags.contains(.shift) || flags.contains(.command)
            let panPoints: CGFloat
            if abs(dx) >= 0.1 {
                panPoints = dx
            } else if acceleratedModifier && abs(dy) >= 0.1 {
                panPoints = dy * 2.5
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

    private var displayedPlayheadSeconds: Double {
        dragVisualPlayheadSeconds ?? playheadSeconds
    }

    private var displayedVisualPlayheadSeconds: Double {
        dragVisualPlayheadSeconds ?? playheadVisualSeconds
    }

    private var canShowClipTranscriptSidebar: Bool {
        !isCompactLayout && model.hasAudioTrack
    }

    private var showsClipTranscriptSidebar: Bool {
        canShowClipTranscriptSidebar && storedTranscriptSidebarVisible
    }

    private var clipTranscriptSidebarMinWidth: CGFloat {
        340
    }

    private var clipTranscriptSidebarMaxWidth: CGFloat {
        920
    }

    private func clampedTranscriptSidebarWidth(_ value: CGFloat) -> CGFloat {
        min(max(value, clipTranscriptSidebarMinWidth), clipTranscriptSidebarMaxWidth)
    }

    private var clipTranscriptSidebarWidth: CGFloat {
        if let liveTranscriptSidebarWidth {
            return clampedTranscriptSidebarWidth(liveTranscriptSidebarWidth)
        }
        return clampedTranscriptSidebarWidth(CGFloat(storedTranscriptSidebarWidth))
    }

    private func playTranscript(from seconds: Double) {
        seekPlayerAndFocusViewport(to: seconds, focusViewport: true)
        springAnimateVisualPlayhead(to: seconds)
        player.playImmediately(atRate: 1.0)
    }

    private var currentPlayerAspectRatio: CGFloat {
        if let resolution = model.sourceInfo?.resolution {
            let sanitized = resolution
                .replacingOccurrences(of: "×", with: "x")
                .replacingOccurrences(of: " ", with: "")
            let components = sanitized.split(separator: "x", maxSplits: 1).map(String.init)
            if components.count == 2,
               let width = Double(components[0]),
               let height = Double(components[1]),
               width > 0, height > 0 {
                return max(0.25, CGFloat(width / height))
            }
        }
        if let item = player.currentItem {
            let presentationSize = item.presentationSize
            if presentationSize.width > 0, presentationSize.height > 0 {
                return max(0.25, presentationSize.width / presentationSize.height)
            }
        }
        return 16.0 / 9.0
    }

    private var preferredPlayerDisplayWidth: CGFloat {
        currentPlayerHeight * currentPlayerAspectRatio
    }

    private var clipPlayerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                if showsClipTranscriptSidebar {
                    let dividerWidth: CGFloat = 16
                    let maxPlayerWidth = max(
                        260,
                        geometry.size.width - clipTranscriptSidebarWidth - dividerWidth
                    )
                    let resolvedPlayerWidth = min(preferredPlayerDisplayWidth, maxPlayerWidth)

                    HStack(alignment: .top, spacing: 12) {
                        Spacer(minLength: 0)

                        InlinePlayerView(player: player)
                            .frame(width: resolvedPlayerWidth, height: currentPlayerHeight)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            .clipShape(RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous))
                            .onTapGesture {
                                dismissTimecodeFieldFocus()
                            }

                        Spacer(minLength: 12)

                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 4)
                            .frame(maxHeight: .infinity)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle().inset(by: -6))
                            .onHover { hovering in
                                if hovering {
                                    NSCursor.resizeLeftRight.set()
                                } else if !isMiddleMousePanning {
                                    NSCursor.arrow.set()
                                }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { value in
                                        if transcriptSidebarResizeStartWidth == nil {
                                            transcriptSidebarResizeStartWidth = clipTranscriptSidebarWidth
                                            transcriptSidebarResizeStartGlobalX = value.startLocation.x
                                        }
                                        let base = transcriptSidebarResizeStartWidth ?? clipTranscriptSidebarWidth
                                        let startX = transcriptSidebarResizeStartGlobalX ?? value.startLocation.x
                                        let deltaX = value.location.x - startX
                                        liveTranscriptSidebarWidth = clampedTranscriptSidebarWidth(base - deltaX)
                                    }
                                    .onEnded { _ in
                                        if let liveTranscriptSidebarWidth {
                                            storedTranscriptSidebarWidth = Double(clampedTranscriptSidebarWidth(liveTranscriptSidebarWidth))
                                        }
                                        liveTranscriptSidebarWidth = nil
                                        transcriptSidebarResizeStartWidth = nil
                                        transcriptSidebarResizeStartGlobalX = nil
                                    }
                            )

                        EquatableView(content:
                            ClipTranscriptSidebarView(
                                transcriptSegments: model.transcriptSegments,
                                transcriptStatusText: model.transcriptStatusText,
                                canGenerateTranscript: model.canGenerateTranscript,
                                isGeneratingTranscript: model.isGeneratingTranscript,
                                hasAudioTrack: model.hasAudioTrack,
                                currentTimeSeconds: clipTranscriptSidebarTimeSeconds,
                                isPlaying: player.rate != 0,
                                isScrubbing: isPlayheadDragActive,
                                reduceTransparency: reduceTransparency,
                                focusSearchFieldToken: clipTranscriptSearchFocusToken,
                                generateTranscript: {
                                    model.generateTranscriptFromInspect()
                                },
                                exportTranscript: {
                                    model.exportTranscriptFromInspect()
                                },
                                seekToTranscriptTime: { seconds in
                                    seekPlayerAndFocusViewport(to: seconds, focusViewport: true)
                                    springAnimateVisualPlayhead(to: seconds)
                                },
                                playTranscriptFromTime: { seconds in
                                    playTranscript(from: seconds)
                                },
                                onCloseTranscript: {
                                    storedTranscriptSidebarVisible = false
                                }
                            )
                        )
                        .frame(width: clipTranscriptSidebarWidth, height: currentPlayerHeight)
                    }
                    .frame(width: geometry.size.width, height: currentPlayerHeight, alignment: .topLeading)
                } else {
                    ZStack(alignment: .topTrailing) {
                        InlinePlayerView(player: player)
                            .frame(maxWidth: .infinity)
                            .frame(height: currentPlayerHeight)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            .clipShape(RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous))
                            .onTapGesture {
                                dismissTimecodeFieldFocus()
                            }

                        if canShowClipTranscriptSidebar {
                            Button {
                                storedTranscriptSidebarVisible = true
                            } label: {
                                Label("Show Transcript", systemImage: "captions.bubble")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(.top, 10)
                            .padding(.trailing, 10)
                            .help("Show Transcript")
                            .accessibilityLabel("Show Transcript")
                        }
                    }
                }
            }
            .frame(height: currentPlayerHeight)

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

            ClipPlayerUtilityRow(
                hasVideoTrack: model.hasVideoTrack,
                playheadSeconds: displayedPlayheadSeconds,
                totalDurationSeconds: max(playerDurationSeconds, model.sourceDurationSeconds),
                playheadCopyFlash: playheadCopyFlash,
                compactZoomDisplayText: compactPlayerZoomDisplayText,
                timelineZoomLevelCount: allowedTimelineZoomLevels.count,
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
                    model.captureFrame(at: displayedPlayheadSeconds)
                },
                onZoomOut: {
                    setTimelineZoomIndex(max(0, timelineZoomIndex - 1))
                },
                onZoomIn: {
                    setTimelineZoomIndex(min(allowedTimelineZoomLevels.count - 1, timelineZoomIndex + 1))
                },
                onFit: {
                    setTimelineZoomIndex(0)
                },
                timelineZoomIndexBinding: Binding(
                    get: { Double(timelineZoomIndex) },
                    set: { setTimelineZoomIndex(Int($0.rounded())) }
                )
            )
        }
        .onChange(of: isCompactLayout) { _ in
            storedPlayerHeight = Double(clampedPlayerHeight(currentPlayerHeight))
        }
    }

    private var compactPlayerZoomDisplayText: String {
        let displayZoom = allowedTimelineZoomLevels[timelineZoomIndex]
        if abs(displayZoom.rounded() - displayZoom) < 0.001 {
            return "\(Int(displayZoom.rounded()))x"
        }
        return String(format: "%.1fx", displayZoom)
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
            playheadVisualSeconds: displayedVisualPlayheadSeconds,
            playheadJumpFromSeconds: playheadJumpFromSeconds,
            playheadJumpAnimationToken: playheadJumpAnimationToken,
            playheadSeconds: displayedPlayheadSeconds,
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
        ClipEmptySourceView(
            emptyStateURLText: $emptyStateURLText,
            isDropTargeted: $isEmptyDropTargeted,
            reduceTransparency: reduceTransparency,
            isURLDownloadEnabled: model.ytDLPAvailable && model.canRequestURLDownload,
            onChooseFile: {
                model.chooseSource()
            },
            onDownload: {
                let trimmed = emptyStateURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                model.startURLImport(
                    urlText: trimmed,
                    preset: model.urlDownloadPreset,
                    saveMode: model.urlDownloadSaveLocationMode,
                    customFolderPath: model.customURLDownloadDirectoryPath
                )
            },
            onHandleDrop: { providers in
                model.handleDrop(providers: providers)
            }
        )
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

    private var urlImportSheetView: some View {
        ClipURLImportSheetView(
            importURLText: $importURLText,
            importURLPreset: $importURLPreset,
            importURLSaveMode: $importURLSaveMode,
            importCustomFolderPath: $importCustomFolderPath,
            showAdvancedOptions: $showURLImportAdvancedOptions,
            clipboardURLString: clipboardURLString,
            onCancel: {
                model.isURLImportSheetPresented = false
            },
            onSubmit: {
                submitURLImportSheet()
            },
            onChooseCustomFolder: {
                model.chooseCustomURLDownloadDirectory()
                importCustomFolderPath = model.customURLDownloadDirectoryPath
            },
            isURLFieldFocused: $isImportURLFieldFocused
        )
        .onAppear {
            if importURLText.isEmpty {
                prepareURLImportSheetDefaults()
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
            clipTranscriptSidebarTimeSeconds = displayedPlayheadSeconds
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
            .onChange(of: displayedPlayheadSeconds) { newValue in
                guard !isPlayheadDragActive else { return }
                clipTranscriptSidebarTimeSeconds = newValue
            }
            .onChange(of: isPlayheadDragActive) { active in
                if !active {
                    clipTranscriptSidebarTimeSeconds = displayedPlayheadSeconds
                }
            }
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
            .onReceive(NotificationCenter.default.publisher(for: .clipFocusTranscriptSearch, object: model)) { _ in
                guard showsClipTranscriptSidebar else { return }
                clipTranscriptSearchFocusToken &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipToggleTranscriptSidebar, object: model)) { _ in
                guard canShowClipTranscriptSidebar else { return }
                storedTranscriptSidebarVisible.toggle()
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
