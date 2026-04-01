import AppKit
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import Combine
import UserNotifications

@MainActor
private final class ClipToolRuntimeState: ObservableObject {
    var waveformTask: Task<Void, Never>?
    var thumbnailStripTask: Task<[TimelineThumbnailTile], Never>?
    var thumbnailStripDebounceTask: Task<Void, Never>?
    var thumbnailStripPrewarmTask: Task<Void, Never>?
    var keyMonitor: Any?
    var flagsMonitor: Any?
    var scrollMonitor: Any?
    var mouseDownMonitor: Any?
    var middleMousePanMonitor: Any?
    var manualViewportPanTask: Task<Void, Never>?
    var manualViewportPanTargetStartSeconds: Double?
    var manualViewportPanResponseFactor: Double = 0.38
    var clipBoundaryVisualSmoothingTask: Task<Void, Never>?
    var isViewportManuallyControlled = false
    var isTimelineHovered = false
    var isWaveformHovered = false
    var timelineInteractiveWidth: CGFloat = 1
    var isMiddleMousePanning = false
    var middleMousePanLastWindowX: CGFloat?
    var loadedSourcePath: String?
    var suppressVisualPlayheadSyncUntil: Date = .distantPast
    var playheadDragLocationX: CGFloat?
    var playheadDragWidth: CGFloat = 0
    var playheadDragAutoPanTask: Task<Void, Never>?
    var lastInteractiveSeekCommitTimestamp: CFTimeInterval = 0
    var lastInteractiveReadoutSyncTimestamp: CFTimeInterval = 0
    var lastSharedPlayheadSyncTimestamp: CFTimeInterval = 0
    var timelinePointerSeconds: Double?
    weak var waveformHostView: WaveformRasterHostView?
    weak var clipWindow: NSWindow?
    var playerTimeObserverToken: Any?
    var selectionPlaybackBoundaryObserverToken: Any?
    var lastPlaybackUIUpdateTimestamp: CFTimeInterval = 0
    var lastPlaybackFollowUpdateTimestamp: CFTimeInterval = 0
    var lastTranscriptSidebarPlaybackUpdateTimestamp: CFTimeInterval = 0
    var selectionPlaybackEndSeconds: Double?
    var lastThumbnailStripRequestKey: String?
    var lastThumbnailStripPrewarmKey: String?
    var lastThumbnailViewportMidpointSeconds: Double?
    var playerResizeStartHeight: CGFloat?
    var playerResizeStartGlobalY: CGFloat?
    var transcriptSidebarResizeStartWidth: CGFloat?
    var transcriptSidebarResizeStartGlobalX: CGFloat?
    var lastInteractiveSeekSeconds: Double = -1
}

private struct ThumbnailStripRequest {
    let startSeconds: Double
    let endSeconds: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let cacheKey: String
}

struct TimelineThumbnailTile {
    let cacheKey: String
    let image: CGImage
    let startSeconds: Double
    let endSeconds: Double
}

private struct ClipPlayerStageSection: View {
    let player: AVPlayer
    let currentPlayerHeight: CGFloat
    let preferredPlayerDisplayWidth: CGFloat
    let showsClipTranscriptSidebar: Bool
    let canShowClipTranscriptSidebar: Bool
    let clipTranscriptSidebarWidth: CGFloat
    let transcriptSegments: [TranscriptSegment]
    let transcriptStatusText: String
    let canGenerateTranscript: Bool
    let isGeneratingTranscript: Bool
    let hasAudioTrack: Bool
    let currentTimeSeconds: Double
    let isPlaying: Bool
    let isScrubbing: Bool
    let reduceTransparency: Bool
    let focusSearchFieldToken: Int
    let isMiddleMousePanning: Bool
    let onDismissTimecodeFieldFocus: () -> Void
    let onAutoFitTranscriptSidebar: (_ maximumSidebarWidth: CGFloat) -> Void
    let onTranscriptSidebarResizeChanged: (_ value: DragGesture.Value) -> Void
    let onTranscriptSidebarResizeEnded: () -> Void
    let onGenerateTranscript: () -> Void
    let onExportTranscript: () -> Void
    let onSeekToTranscriptTime: (_ seconds: Double) -> Void
    let onPlayTranscriptFromTime: (_ seconds: Double) -> Void
    let onCloseTranscript: () -> Void
    let onShowTranscript: () -> Void

    var body: some View {
        GeometryReader { geometry in
            if showsClipTranscriptSidebar {
                let rowSpacing: CGFloat = 12
                let dividerHandleWidth: CGFloat = 4
                let minimumPlayerRegionWidth: CGFloat = 260
                let maximumSidebarWidth = max(
                    220,
                    geometry.size.width - minimumPlayerRegionWidth - dividerHandleWidth - (rowSpacing * 2)
                )
                let sidebarWidth = min(clipTranscriptSidebarWidth, maximumSidebarWidth)
                let playerRegionWidth = max(
                    minimumPlayerRegionWidth,
                    geometry.size.width - sidebarWidth - dividerHandleWidth - (rowSpacing * 2)
                )
                let resolvedPlayerWidth = min(preferredPlayerDisplayWidth, playerRegionWidth)

                HStack(alignment: .top, spacing: rowSpacing) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)

                        InlinePlayerView(player: player)
                            .frame(width: resolvedPlayerWidth, height: currentPlayerHeight)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            .clipShape(RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous))
                            .onTapGesture {
                                onDismissTimecodeFieldFocus()
                            }

                        Spacer(minLength: 0)
                    }
                    .frame(width: playerRegionWidth, height: currentPlayerHeight, alignment: .center)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: dividerHandleWidth)
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
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                onAutoFitTranscriptSidebar(maximumSidebarWidth)
                            }
                        )
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    onTranscriptSidebarResizeChanged(value)
                                }
                                .onEnded { _ in
                                    onTranscriptSidebarResizeEnded()
                                }
                        )

                    EquatableView(content:
                        ClipTranscriptSidebarView(
                            transcriptSegments: transcriptSegments,
                            transcriptStatusText: transcriptStatusText,
                            canGenerateTranscript: canGenerateTranscript,
                            isGeneratingTranscript: isGeneratingTranscript,
                            hasAudioTrack: hasAudioTrack,
                            currentTimeSeconds: currentTimeSeconds,
                            isPlaying: isPlaying,
                            isScrubbing: isScrubbing,
                            reduceTransparency: reduceTransparency,
                            focusSearchFieldToken: focusSearchFieldToken,
                            generateTranscript: onGenerateTranscript,
                            exportTranscript: onExportTranscript,
                            seekToTranscriptTime: onSeekToTranscriptTime,
                            playTranscriptFromTime: onPlayTranscriptFromTime,
                            onCloseTranscript: onCloseTranscript
                        )
                    )
                    .frame(width: sidebarWidth, height: currentPlayerHeight)
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
                            onDismissTimecodeFieldFocus()
                        }

                    if canShowClipTranscriptSidebar {
                        Button(action: onShowTranscript) {
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
    }
}

extension ClipPlayerStageSection: Equatable {
    static func == (lhs: ClipPlayerStageSection, rhs: ClipPlayerStageSection) -> Bool {
        ObjectIdentifier(lhs.player) == ObjectIdentifier(rhs.player) &&
        lhs.currentPlayerHeight == rhs.currentPlayerHeight &&
        lhs.preferredPlayerDisplayWidth == rhs.preferredPlayerDisplayWidth &&
        lhs.showsClipTranscriptSidebar == rhs.showsClipTranscriptSidebar &&
        lhs.canShowClipTranscriptSidebar == rhs.canShowClipTranscriptSidebar &&
        lhs.clipTranscriptSidebarWidth == rhs.clipTranscriptSidebarWidth &&
        lhs.transcriptSegments.count == rhs.transcriptSegments.count &&
        lhs.transcriptSegments.first?.id == rhs.transcriptSegments.first?.id &&
        lhs.transcriptSegments.last?.id == rhs.transcriptSegments.last?.id &&
        lhs.transcriptStatusText == rhs.transcriptStatusText &&
        lhs.canGenerateTranscript == rhs.canGenerateTranscript &&
        lhs.isGeneratingTranscript == rhs.isGeneratingTranscript &&
        lhs.hasAudioTrack == rhs.hasAudioTrack &&
        lhs.currentTimeSeconds == rhs.currentTimeSeconds &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.isScrubbing == rhs.isScrubbing &&
        lhs.reduceTransparency == rhs.reduceTransparency &&
        lhs.focusSearchFieldToken == rhs.focusSearchFieldToken &&
        lhs.isMiddleMousePanning == rhs.isMiddleMousePanning
    }
}

struct ClipToolView: View {
    private enum ClipBoundaryDragKind {
        case start
        case end
    }

    let model: WorkspaceViewModel
    @ObservedObject var sourcePresentation: SourcePresentationModel
    @ObservedObject var clipTimelinePresentation: ClipTimelinePresentationModel
    let isCompactLayout: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.undoManager) private var undoManager

    @StateObject private var runtime = ClipToolRuntimeState()
    @State private var player = AVPlayer()
    @State private var playheadSeconds: Double = 0
    @State private var playerDurationSeconds: Double = 0
    @State private var waveformSamples: [Double] = []
    @State private var isWaveformLoading = false
    @State private var thumbnailTiles: [TimelineThumbnailTile] = []
    @State private var thumbnailTilesRevision: Int = 0
    @State private var thumbnailStripImage: CGImage?
    @State private var thumbnailStripRevision: Int = 0
    @State private var thumbnailStripShouldCrossfade = false
    @State private var isThumbnailStripLoading = false
    @State private var thumbnailStripSourceStartSeconds: Double = 0
    @State private var thumbnailStripSourceEndSeconds: Double = 0
    @State private var thumbnailStripSourceVisibleDurationSeconds: Double = 0
    @State private var thumbnailStripSourceViewportWidth: CGFloat = 0
    @State private var timelineInteractiveWidth: CGFloat = 1
    @State private var timelineZoom: Double = 1.0
    @State private var viewportStartSeconds: Double = 0
    @State private var isOptionKeyPressed = false
    @State private var playheadVisualSeconds: Double = 0
    @State private var playheadJumpAnimationToken: Int = 0
    @State private var playheadJumpFromSeconds: Double = 0
    @State private var isPlayheadDragActive = false
    @State private var playheadCopyFlash = false
    @State private var dragVisualPlayheadSeconds: Double?
    @State private var isClipBoundaryDragActive = false
    @State private var activeClipBoundaryDragKind: ClipBoundaryDragKind?
    @State private var pendingClipStartSeconds: Double = 0
    @State private var pendingClipEndSeconds: Double = 0
    @State private var visualClipStartSeconds: Double = 0
    @State private var visualClipEndSeconds: Double = 0
    @State private var clipContentHeight: CGFloat = 0
    @SceneStorage("clip.playerHeight") private var storedPlayerHeight: Double = 0
    @SceneStorage("clip.transcriptSidebarWidth") private var storedTranscriptSidebarWidth: Double = 440
    @SceneStorage("clip.transcriptSidebarVisible") private var storedTranscriptSidebarVisible = true
    @State private var livePlayerHeight: CGFloat?
    @State private var liveTranscriptSidebarWidth: CGFloat?
    @State private var clipTranscriptSidebarTimeSeconds: Double = 0
    @State private var clipTranscriptSearchFocusToken: Int = 0
    @State private var importURLText: String = ""
    @State private var importURLPreset: URLDownloadPreset = .compatibleBest
    @State private var importURLSaveMode: URLDownloadSaveLocationMode = .askEachTime
    @State private var importCustomFolderPath: String = ""
    @State private var importURLAuthenticationMode: URLDownloadAuthenticationMode = .none
    @State private var importURLBrowserCookiesSource: URLDownloadBrowserCookiesSource = .firefox
    @State private var showURLImportAdvancedOptions = false
    @State private var emptyStateURLText: String = ""
    @State private var isEmptyDropTargeted = false
    @FocusState private var isImportURLFieldFocused: Bool

    private var clip: ClipTimelinePresentationModel { clipTimelinePresentation }

    private var displayedClipStartSeconds: Double {
        isClipBoundaryDragActive ? visualClipStartSeconds : clip.clipStartSeconds
    }

    private var displayedClipEndSeconds: Double {
        isClipBoundaryDragActive ? visualClipEndSeconds : clip.clipEndSeconds
    }

    private var thumbnailStripHeight: CGFloat {
        sourcePresentation.hasVideoTrack ? (isCompactLayout ? 36 : 44) : 0
    }

    private var timelinePanelHeight: CGFloat {
        if sourcePresentation.hasVideoTrack {
            return isCompactLayout ? 104 : 126
        }
        return isCompactLayout ? 68 : 82
    }

    private var isBenchmarkReady: Bool {
        PlayheadDiagnostics.shared.isEnabled &&
        sourcePresentation.sourceURL != nil &&
        !isWaveformLoading &&
        timelineInteractiveWidth > 0 &&
        player.currentItem != nil
    }

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

    private func syncVisualPlayheadImmediately(_ value: Double) {
        playheadVisualSeconds = value
        playheadJumpFromSeconds = value
        runtime.suppressVisualPlayheadSyncUntil = .distantPast
    }

    private func springAnimateVisualPlayhead(to value: Double) {
        playheadJumpFromSeconds = playheadVisualSeconds
        playheadVisualSeconds = value
        playheadJumpAnimationToken &+= 1
        runtime.suppressVisualPlayheadSyncUntil = Date().addingTimeInterval(0.22)
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
        stopManualViewportPan()
        let clamped = min(max(0, index), allowedTimelineZoomLevels.count - 1)
        let next = allowedTimelineZoomLevels[clamped]
        guard abs(timelineZoom - next) > 0.0001 else { return }

        let oldZoom = max(1.0, timelineZoom)
        let oldWindow = max(0.25, totalDurationSeconds / oldZoom)
        let oldStart = oldZoom <= 1 ? 0 : clampedViewportStart(viewportStartSeconds)

        let playheadAnchorSeconds = min(max(0, playheadVisualSeconds), totalDurationSeconds)
        let anchorSeconds: Double = {
            if runtime.isWaveformHovered, let pointer = runtime.timelinePointerSeconds {
                return min(max(0, pointer), totalDurationSeconds)
            }
            return playheadAnchorSeconds
        }()
        let usingPointerAnchor = runtime.isWaveformHovered && runtime.timelinePointerSeconds != nil
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
            runtime.isViewportManuallyControlled = false
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
        runtime.isViewportManuallyControlled = true
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
            return max(0, min(current, max(playerDurationSeconds, sourcePresentation.sourceDurationSeconds)))
        }
        return playheadSeconds
    }

    private func installPlayerTimeObserverIfNeeded() {
        guard runtime.playerTimeObserverToken == nil else { return }
        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        runtime.playerTimeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            MainActor.assumeIsolated {
                let current = CMTimeGetSeconds(time)
                if current.isFinite {
                    let newPlayhead = max(0, current)
                    let didMove = abs(newPlayhead - playheadSeconds) > (1.0 / 240.0)

                    if didMove {
                        let now = CACurrentMediaTime()
                        let isPlaying = player.rate != 0
                        let uiUpdateInterval = isPlaying ? (1.0 / 30.0) : (1.0 / 60.0)
                        if !isPlaying || (now - runtime.lastPlaybackUIUpdateTimestamp) >= uiUpdateInterval {
                            playheadSeconds = newPlayhead
                            if Date() >= runtime.suppressVisualPlayheadSyncUntil {
                                playheadVisualSeconds = newPlayhead
                            }
                            runtime.lastPlaybackUIUpdateTimestamp = now
                        }
                        // Avoid high-frequency @Published writes while playback is active.
                        // Persist shared playhead state only while paused or on explicit actions.
                        if !isPlaying {
                            syncSharedPlayheadStateIfNeeded(newPlayhead, force: false, updateAlignment: true)
                        }
                    }

                    if let selectionPlaybackEndSeconds = runtime.selectionPlaybackEndSeconds,
                       player.rate != 0,
                       newPlayhead >= (selectionPlaybackEndSeconds - (1.0 / 240.0)) {
                        player.pause()
                        let clampedEnd = max(clip.clipStartSeconds, min(selectionPlaybackEndSeconds, max(playerDurationSeconds, sourcePresentation.sourceDurationSeconds)))
                        let endTime = CMTime(seconds: clampedEnd, preferredTimescale: 600)
                        player.seek(to: endTime, toleranceBefore: .zero, toleranceAfter: .zero)
                        playheadSeconds = clampedEnd
                        playheadVisualSeconds = clampedEnd
                        syncSharedPlayheadStateIfNeeded(clampedEnd, force: true, updateAlignment: true)
                        clearSelectionPlaybackState()
                        return
                    }

                    if player.rate != 0 {
                        // While playing, keep manual viewport control until the playhead actually
                        // leaves the visible window. At that point, reveal it with a larger step
                        // instead of continuous auto-scrolling.
                        let playheadOffscreen = newPlayhead < visibleStartSeconds || newPlayhead > visibleEndSeconds
                        let shouldFollow = !runtime.isViewportManuallyControlled
                        if shouldFollow || playheadOffscreen {
                            let now = CACurrentMediaTime()
                            if (now - runtime.lastPlaybackFollowUpdateTimestamp) >= (1.0 / 20.0) {
                                updateViewportForPlayhead(shouldFollow: true)
                                runtime.lastPlaybackFollowUpdateTimestamp = now
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
    }

    private func removePlayerTimeObserver() {
        guard let token = runtime.playerTimeObserverToken else { return }
        player.removeTimeObserver(token)
        runtime.playerTimeObserverToken = nil
        runtime.lastPlaybackUIUpdateTimestamp = 0
        runtime.lastPlaybackFollowUpdateTimestamp = 0
        runtime.lastTranscriptSidebarPlaybackUpdateTimestamp = 0
        clearSelectionPlaybackState()
    }

    private func clearSelectionPlaybackState() {
        if let token = runtime.selectionPlaybackBoundaryObserverToken {
            player.removeTimeObserver(token)
            runtime.selectionPlaybackBoundaryObserverToken = nil
        }
        runtime.selectionPlaybackEndSeconds = nil
    }

    private func installSelectionPlaybackBoundaryObserver(endSeconds: Double) {
        if let token = runtime.selectionPlaybackBoundaryObserverToken {
            player.removeTimeObserver(token)
            runtime.selectionPlaybackBoundaryObserverToken = nil
        }

        runtime.selectionPlaybackEndSeconds = endSeconds
        let endTime = CMTime(seconds: endSeconds, preferredTimescale: 600)
        runtime.selectionPlaybackBoundaryObserverToken = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endTime)],
            queue: .main
        ) {
            MainActor.assumeIsolated {
                player.pause()
                player.seek(to: endTime, toleranceBefore: .zero, toleranceAfter: .zero)
                playheadSeconds = endSeconds
                playheadVisualSeconds = endSeconds
                syncSharedPlayheadStateIfNeeded(endSeconds, force: true, updateAlignment: true)
                clearSelectionPlaybackState()
            }
        }
    }

    private func loadPlayerItem() {
        guard let sourceURL = sourcePresentation.sourceURL else {
            removePlayerTimeObserver()
            player.replaceCurrentItem(with: nil)
            playheadSeconds = 0
            playheadVisualSeconds = 0
            playerDurationSeconds = 0
            runtime.loadedSourcePath = nil
            runtime.waveformTask?.cancel()
            waveformSamples = []
            isWaveformLoading = false
            return
        }

        if runtime.loadedSourcePath == sourceURL.path, player.currentItem != nil {
            let duration = max(playerDurationSeconds, sourcePresentation.sourceDurationSeconds)
            let restored = max(0, min(clip.clipPlayheadSeconds, duration))
            if abs(playheadSeconds - restored) > (1.0 / 120.0) {
                seekPlayer(to: restored)
            } else {
                syncVisualPlayheadImmediately(restored)
            }
            return
        }

        runtime.loadedSourcePath = sourceURL.path
        let item = AVPlayerItem(url: sourceURL)
        player.replaceCurrentItem(with: item)
        installPlayerTimeObserverIfNeeded()
        let duration = CMTimeGetSeconds(item.asset.duration)
        playerDurationSeconds = duration.isFinite && duration > 0 ? duration : sourcePresentation.sourceDurationSeconds
        let restored = max(0, min(clip.clipPlayheadSeconds, max(playerDurationSeconds, sourcePresentation.sourceDurationSeconds)))
        playheadSeconds = restored
        syncVisualPlayheadImmediately(restored)
        stopManualViewportPan()
        viewportStartSeconds = 0
        clampTimelineZoomToAllowedLevels()
        player.seek(to: CMTime(seconds: restored, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        loadWaveform(for: sourceURL)
    }

    private func loadWaveform(for url: URL) {
        runtime.waveformTask?.cancel()

        // Keep long timelines detailed when zoomed in: higher bucket density than real-time display rate.
        let targetSampleCount = Int(min(240_000, max(12_000, sourcePresentation.sourceDurationSeconds * 120.0)))

        if let cachedSamples = model.waveformSamplesFromCache(for: url, sampleCount: targetSampleCount), !cachedSamples.isEmpty {
            waveformSamples = cachedSamples
            isWaveformLoading = false
            return
        }

        waveformSamples = []
        isWaveformLoading = true

        runtime.waveformTask = Task.detached(priority: .userInitiated) {
            let samples = generateWaveformSamples(for: url, sampleCount: targetSampleCount)
            await MainActor.run {
                self.model.cacheWaveformSamples(samples, for: url, sampleCount: targetSampleCount)
                self.waveformSamples = samples
                self.isWaveformLoading = false
            }
        }
    }

    private func clearThumbnailStrip() {
        runtime.thumbnailStripTask?.cancel()
        runtime.thumbnailStripTask = nil
        runtime.thumbnailStripDebounceTask?.cancel()
        runtime.thumbnailStripDebounceTask = nil
        runtime.thumbnailStripPrewarmTask?.cancel()
        runtime.thumbnailStripPrewarmTask = nil
        runtime.lastThumbnailStripRequestKey = nil
        runtime.lastThumbnailStripPrewarmKey = nil
        thumbnailTiles = []
        thumbnailTilesRevision &+= 1
        thumbnailStripImage = nil
        thumbnailStripShouldCrossfade = false
        thumbnailStripRevision &+= 1
        thumbnailStripSourceStartSeconds = 0
        thumbnailStripSourceEndSeconds = 0
        thumbnailStripSourceVisibleDurationSeconds = 0
        thumbnailStripSourceViewportWidth = 0
        isThumbnailStripLoading = false
    }

    private func thumbnailGenerationRange() -> (start: Double, end: Double)? {
        guard visibleEndSeconds > visibleStartSeconds, totalDurationSeconds > 0 else { return nil }
        let visibleDuration = visibleEndSeconds - visibleStartSeconds
        let padding = visibleDuration * 0.35
        let start = max(0, visibleStartSeconds - padding)
        let end = min(totalDurationSeconds, visibleEndSeconds + padding)
        guard end > start else { return nil }
        return (start, end)
    }

    private func thumbnailTileRequests(
        sourceURL: URL,
        scale: CGFloat,
        scrollDirection: Int
    ) -> (display: [ThumbnailStripRequest], prewarm: [ThumbnailStripRequest], requestKey: String)? {
        guard visibleEndSeconds > visibleStartSeconds,
              totalDurationSeconds > 0,
              timelineInteractiveWidth > 0,
              thumbnailStripHeight > 0 else { return nil }

        let visibleDuration = visibleEndSeconds - visibleStartSeconds
        let tilesPerViewport = 4
        let displayPrewarmTilesPerSide = 2
        let tileDuration = max(0.1, visibleDuration / Double(tilesPerViewport))
        let pixelsPerSecond = Double(max(1, timelineInteractiveWidth) * scale) / max(0.0001, visibleDuration)
        let pixelHeight = max(1, Int((thumbnailStripHeight * scale).rounded()))
        let totalTileCount = max(1, Int(ceil(totalDurationSeconds / tileDuration)))
        let firstVisibleIndex = max(0, min(totalTileCount - 1, Int(floor(visibleStartSeconds / tileDuration))))
        let lastVisibleIndex = max(firstVisibleIndex, min(totalTileCount - 1, Int(ceil(visibleEndSeconds / tileDuration)) - 1))
        let displayFirstIndex = max(0, firstVisibleIndex - displayPrewarmTilesPerSide)
        let displayLastIndex = min(totalTileCount - 1, lastVisibleIndex + displayPrewarmTilesPerSide)

        func request(for index: Int) -> ThumbnailStripRequest? {
            let startSeconds = min(totalDurationSeconds, Double(index) * tileDuration)
            let endSeconds = min(totalDurationSeconds, startSeconds + tileDuration)
            return makeThumbnailStripRequest(
                sourceURL: sourceURL,
                startSeconds: startSeconds,
                endSeconds: endSeconds,
                pixelsPerSecond: pixelsPerSecond,
                pixelHeight: pixelHeight
            )
        }

        let displayRequests = (displayFirstIndex...displayLastIndex).compactMap(request(for:))
        guard !displayRequests.isEmpty else { return nil }

        let visibleCenterIndex = Double(firstVisibleIndex + lastVisibleIndex) * 0.5
        var prewarmIndices: [Int] = []
        prewarmIndices.reserveCapacity(max(0, totalTileCount - displayRequests.count))

        for index in 0..<totalTileCount where index < displayFirstIndex || index > displayLastIndex {
            prewarmIndices.append(index)
        }

        prewarmIndices.sort { lhs, rhs in
            let lhsDistance = abs(Double(lhs) - visibleCenterIndex)
            let rhsDistance = abs(Double(rhs) - visibleCenterIndex)
            if abs(lhsDistance - rhsDistance) > 0.001 {
                return lhsDistance < rhsDistance
            }

            if scrollDirection > 0 {
                let lhsAhead = lhs > lastVisibleIndex
                let rhsAhead = rhs > lastVisibleIndex
                if lhsAhead != rhsAhead {
                    return lhsAhead
                }
            } else if scrollDirection < 0 {
                let lhsBehind = lhs < firstVisibleIndex
                let rhsBehind = rhs < firstVisibleIndex
                if lhsBehind != rhsBehind {
                    return lhsBehind
                }
            }

            return lhs < rhs
        }

        let prewarmRequests = prewarmIndices.compactMap(request(for:))
        let requestKey = displayRequests.map(\.cacheKey).joined(separator: "|")
        return (displayRequests, prewarmRequests, requestKey)
    }

    private func makeThumbnailStripRequest(
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        pixelsPerSecond: Double,
        pixelHeight: Int
    ) -> ThumbnailStripRequest? {
        guard endSeconds > startSeconds else { return nil }
        let pixelWidth = max(1, Int((max(0.0001, endSeconds - startSeconds) * pixelsPerSecond).rounded()))
        return ThumbnailStripRequest(
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            cacheKey: timelineThumbnailStripCacheKey(
                for: sourceURL,
                visibleStartSeconds: startSeconds,
                visibleEndSeconds: endSeconds,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        )
    }

    private func mergedThumbnailTiles(
        _ existing: [TimelineThumbnailTile],
        with incoming: [TimelineThumbnailTile]
    ) -> [TimelineThumbnailTile] {
        guard !incoming.isEmpty else { return existing }
        var tilesByKey: [String: TimelineThumbnailTile] = [:]
        tilesByKey.reserveCapacity(existing.count + incoming.count)
        for tile in existing {
            tilesByKey[tile.cacheKey] = tile
        }
        for tile in incoming {
            tilesByKey[tile.cacheKey] = tile
        }
        return tilesByKey.values.sorted { lhs, rhs in
            if abs(lhs.startSeconds - rhs.startSeconds) > 0.0001 {
                return lhs.startSeconds < rhs.startSeconds
            }
            return lhs.cacheKey < rhs.cacheKey
        }
    }

    private func scheduleThumbnailTilePrewarm(
        requests: [ThumbnailStripRequest],
        anchorRequestKey: String,
        sourceURL: URL
    ) {
        runtime.thumbnailStripPrewarmTask?.cancel()
        runtime.thumbnailStripPrewarmTask = nil
        runtime.lastThumbnailStripPrewarmKey = nil

        guard !requests.isEmpty else { return }

        let uncachedRequests = requests.filter { model.timelineThumbnailStripImageFromCache(forKey: $0.cacheKey) == nil }
        guard !uncachedRequests.isEmpty else { return }

        runtime.lastThumbnailStripPrewarmKey = anchorRequestKey
        let totalDuration = totalDurationSeconds

        runtime.thumbnailStripPrewarmTask = Task.detached(priority: .utility) { [model] in
            let batchSize = 3
            var nextBatchStart = 0

            while nextBatchStart < uncachedRequests.count {
                guard !Task.isCancelled else { return }

                let batchEnd = min(uncachedRequests.count, nextBatchStart + batchSize)
                let batch = Array(uncachedRequests[nextBatchStart..<batchEnd])
                nextBatchStart = batchEnd

                await withTaskGroup(of: (ThumbnailStripRequest, CGImage?).self) { group in
                    for request in batch {
                        group.addTask {
                            guard !Task.isCancelled else { return (request, nil) }

                            let alreadyCached = await MainActor.run {
                                model.timelineThumbnailStripImageFromCache(forKey: request.cacheKey) != nil
                            }
                            if alreadyCached {
                                return (request, nil)
                            }

                            let image = await generateTimelineThumbnailStripImage(
                                fileURL: sourceURL,
                                visibleStartSeconds: request.startSeconds,
                                visibleEndSeconds: request.endSeconds,
                                totalDurationSeconds: totalDuration,
                                pixelWidth: request.pixelWidth,
                                pixelHeight: request.pixelHeight,
                                shouldCancel: { Task.isCancelled }
                            )
                            return (request, image)
                        }
                    }

                    for await (request, image) in group {
                        guard !Task.isCancelled else { return }
                        guard let image else { continue }
                        await MainActor.run {
                            if model.timelineThumbnailStripImageFromCache(forKey: request.cacheKey) == nil {
                                model.cacheTimelineThumbnailStripImage(image, forKey: request.cacheKey)
                            }
                        }
                    }
                }
            }
        }
    }

    private func scheduleThumbnailStripGeneration(immediate: Bool = false) {
        guard sourcePresentation.hasVideoTrack,
              let sourceURL = sourcePresentation.sourceURL,
              timelineInteractiveWidth > 0,
              thumbnailStripHeight > 0,
              visibleEndSeconds > visibleStartSeconds else {
            clearThumbnailStrip()
            return
        }

        let scale = runtime.clipWindow?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let currentMidpoint = (visibleStartSeconds + visibleEndSeconds) * 0.5
        let previousMidpoint = runtime.lastThumbnailViewportMidpointSeconds
        runtime.lastThumbnailViewportMidpointSeconds = currentMidpoint
        let scrollDirection: Int = {
            guard let previousMidpoint else { return 0 }
            if currentMidpoint > previousMidpoint { return 1 }
            if currentMidpoint < previousMidpoint { return -1 }
            return 0
        }()

        guard let tilePlan = thumbnailTileRequests(
            sourceURL: sourceURL,
            scale: scale,
            scrollDirection: scrollDirection
        ) else {
            clearThumbnailStrip()
            return
        }

        if runtime.lastThumbnailStripRequestKey == tilePlan.requestKey,
           !thumbnailTiles.isEmpty || isThumbnailStripLoading {
            return
        }

        runtime.lastThumbnailStripRequestKey = tilePlan.requestKey

        let cachedDisplayTiles = tilePlan.display.compactMap { request -> TimelineThumbnailTile? in
            guard let image = model.timelineThumbnailStripImageFromCache(forKey: request.cacheKey) else { return nil }
            return TimelineThumbnailTile(
                cacheKey: request.cacheKey,
                image: image,
                startSeconds: request.startSeconds,
                endSeconds: request.endSeconds
            )
        }

        let mergedCachedDisplayTiles = mergedThumbnailTiles(thumbnailTiles, with: cachedDisplayTiles)
        if mergedCachedDisplayTiles.map(\.cacheKey) != thumbnailTiles.map(\.cacheKey) {
            thumbnailTiles = mergedCachedDisplayTiles
            thumbnailTilesRevision &+= 1
        }

        let allDisplayTilesCached = cachedDisplayTiles.count == tilePlan.display.count
        if allDisplayTilesCached {
            isThumbnailStripLoading = false
            scheduleThumbnailTilePrewarm(
                requests: tilePlan.prewarm,
                anchorRequestKey: tilePlan.requestKey,
                sourceURL: sourceURL
            )
            return
        }

        runtime.thumbnailStripDebounceTask?.cancel()
        runtime.thumbnailStripTask?.cancel()
        isThumbnailStripLoading = true

        let requests = tilePlan.display
        let requestKey = tilePlan.requestKey
        let totalDuration = totalDurationSeconds
        let debounceNanoseconds: UInt64 = immediate ? 0 : 150_000_000

        runtime.thumbnailStripDebounceTask = Task { @MainActor in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled else { return }

            runtime.thumbnailStripTask?.cancel()
            runtime.thumbnailStripTask = Task.detached(priority: .utility) { [model] in
                var tiles: [TimelineThumbnailTile] = []
                tiles.reserveCapacity(requests.count)

                for request in requests {
                    guard !Task.isCancelled else { return [] }

                    let cachedImage = await MainActor.run {
                        model.timelineThumbnailStripImageFromCache(forKey: request.cacheKey)
                    }

                    if let cachedImage {
                        tiles.append(
                            TimelineThumbnailTile(
                                cacheKey: request.cacheKey,
                                image: cachedImage,
                                startSeconds: request.startSeconds,
                                endSeconds: request.endSeconds
                            )
                        )
                        continue
                    }

                    guard let image = await generateTimelineThumbnailStripImage(
                        fileURL: sourceURL,
                        visibleStartSeconds: request.startSeconds,
                        visibleEndSeconds: request.endSeconds,
                        totalDurationSeconds: totalDuration,
                        pixelWidth: request.pixelWidth,
                        pixelHeight: request.pixelHeight,
                        shouldCancel: { Task.isCancelled }
                    ) else {
                        continue
                    }

                    await MainActor.run {
                        model.cacheTimelineThumbnailStripImage(image, forKey: request.cacheKey)
                    }

                    tiles.append(
                        TimelineThumbnailTile(
                            cacheKey: request.cacheKey,
                            image: image,
                            startSeconds: request.startSeconds,
                            endSeconds: request.endSeconds
                        )
                    )
                }

                return tiles
            }

            let tiles = await runtime.thumbnailStripTask?.value ?? []
            guard !Task.isCancelled, runtime.lastThumbnailStripRequestKey == requestKey else { return }

            thumbnailTiles = mergedThumbnailTiles(thumbnailTiles, with: tiles)
            thumbnailTilesRevision &+= 1
            thumbnailStripImage = nil
            thumbnailStripShouldCrossfade = false
            thumbnailStripSourceStartSeconds = 0
            thumbnailStripSourceEndSeconds = 0
            thumbnailStripSourceVisibleDurationSeconds = 0
            thumbnailStripSourceViewportWidth = 0
            isThumbnailStripLoading = false

            scheduleThumbnailTilePrewarm(
                requests: tilePlan.prewarm,
                anchorRequestKey: requestKey,
                sourceURL: sourceURL
            )
        }
    }

    private func syncDisplayedClipRangeImmediately() {
        pendingClipStartSeconds = clip.clipStartSeconds
        pendingClipEndSeconds = clip.clipEndSeconds
        visualClipStartSeconds = pendingClipStartSeconds
        visualClipEndSeconds = pendingClipEndSeconds
    }

    private func stopClipBoundaryVisualSmoothing() {
        runtime.clipBoundaryVisualSmoothingTask?.cancel()
        runtime.clipBoundaryVisualSmoothingTask = nil
    }

    private func startClipBoundaryVisualSmoothingIfNeeded() {
        guard runtime.clipBoundaryVisualSmoothingTask == nil else { return }
        runtime.clipBoundaryVisualSmoothingTask = Task { @MainActor in
            while !Task.isCancelled && isClipBoundaryDragActive {
                let targetStart = pendingClipStartSeconds
                let targetEnd = pendingClipEndSeconds
                let secondsPerPixel = zoomedWindowDuration / Double(max(1, runtime.timelineInteractiveWidth))
                let settleThreshold = max(secondsPerPixel * 0.25, 1.0 / 480.0)

                let startDelta = targetStart - visualClipStartSeconds
                let endDelta = targetEnd - visualClipEndSeconds

                if abs(startDelta) <= settleThreshold {
                    visualClipStartSeconds = targetStart
                } else {
                    visualClipStartSeconds += startDelta * 0.58
                }

                if abs(endDelta) <= settleThreshold {
                    visualClipEndSeconds = targetEnd
                } else {
                    visualClipEndSeconds += endDelta * 0.58
                }

                try? await Task.sleep(nanoseconds: 16_000_000)
            }

            runtime.clipBoundaryVisualSmoothingTask = nil
        }
    }

    private func setClipBoundaryDragActive(_ active: Bool) {
        guard isClipBoundaryDragActive != active else { return }
        isClipBoundaryDragActive = active
        if active {
            activeClipBoundaryDragKind = nil
            syncDisplayedClipRangeImmediately()
            startClipBoundaryVisualSmoothingIfNeeded()
        } else {
            stopClipBoundaryVisualSmoothing()
            if let dragKind = activeClipBoundaryDragKind {
                switch dragKind {
                case .start:
                    model.setClipStart(pendingClipStartSeconds, undoManager: undoManager)
                case .end:
                    model.setClipEnd(pendingClipEndSeconds, undoManager: undoManager)
                }
            }
            activeClipBoundaryDragKind = nil
            syncDisplayedClipRangeImmediately()
        }
    }

    private func previewClipStartDuringDrag(_ time: Double) {
        let clamped = min(max(0, time), pendingClipEndSeconds)
        activeClipBoundaryDragKind = .start
        pendingClipStartSeconds = clamped
        if !isClipBoundaryDragActive {
            model.setClipStart(clamped, undoManager: undoManager)
            syncDisplayedClipRangeImmediately()
        }
    }

    private func previewClipEndDuringDrag(_ time: Double) {
        let clamped = max(min(totalDurationSeconds, time), pendingClipStartSeconds)
        activeClipBoundaryDragKind = .end
        pendingClipEndSeconds = clamped
        if !isClipBoundaryDragActive {
            model.setClipEnd(clamped, undoManager: undoManager)
            syncDisplayedClipRangeImmediately()
        }
    }

    private func seekPlayer(to time: Double) {
        let clamped = max(0, min(time, max(playerDurationSeconds, sourcePresentation.sourceDurationSeconds)))
        stopManualViewportPan()
        runtime.lastInteractiveSeekSeconds = -1
        dragVisualPlayheadSeconds = nil
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playheadSeconds = clamped
        syncSharedPlayheadStateIfNeeded(clamped, force: true)
        syncVisualPlayheadImmediately(clamped)
        updateViewportForPlayhead(shouldFollow: !runtime.isViewportManuallyControlled || player.rate != 0)
    }

    private func commitInteractiveSeek(to time: Double) {
        let clamped = max(0, min(time, max(playerDurationSeconds, sourcePresentation.sourceDurationSeconds)))

        // Coalesce tiny drag deltas so scrubbing stays responsive without flooding seeks.
        if runtime.lastInteractiveSeekSeconds >= 0, abs(clamped - runtime.lastInteractiveSeekSeconds) < (1.0 / 120.0) {
            PlayheadDiagnostics.shared.noteModelWrite("interactive_seek_delta_coalesced")
            return
        }
        runtime.lastInteractiveSeekSeconds = clamped

        let tolerance = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        let seekID = UUID().uuidString
        PlayheadDiagnostics.shared.noteModelWrite("interactive_player_seek")
        PlayheadDiagnostics.shared.noteInteractiveSeekRequested(id: seekID)
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { finished in
            Task { @MainActor in
                PlayheadDiagnostics.shared.noteInteractiveSeekCompleted(id: seekID, finished: finished)
            }
        }
        playheadSeconds = clamped
        syncSharedPlayheadStateIfNeeded(clamped, force: false, updateAlignment: false)
        playheadVisualSeconds = clamped
        updateViewportForPlayhead(shouldFollow: false)
    }

    private func seekPlayerInteractive(to time: Double, forceCommit: Bool = false) {
        let clamped = max(0, min(time, max(playerDurationSeconds, sourcePresentation.sourceDurationSeconds)))

        let now = CACurrentMediaTime()
        let readoutInterval = 1.0 / 30.0
        if forceCommit || (now - runtime.lastInteractiveReadoutSyncTimestamp) >= readoutInterval {
            dragVisualPlayheadSeconds = clamped
            playheadVisualSeconds = clamped
            runtime.lastInteractiveReadoutSyncTimestamp = now
        }

        let commitInterval = 1.0 / 30.0
        guard forceCommit || (now - runtime.lastInteractiveSeekCommitTimestamp) >= commitInterval else {
            PlayheadDiagnostics.shared.noteModelWrite("interactive_seek_rate_limited")
            return
        }
        runtime.lastInteractiveSeekCommitTimestamp = now
        PlayheadDiagnostics.shared.noteModelWrite("interactive_seek_commit_gate_pass")
        commitInteractiveSeek(to: clamped)
    }

    private func seekPlayerAnimatedFromKeyboard(to time: Double) {
        let clamped = max(0, min(time, max(playerDurationSeconds, sourcePresentation.sourceDurationSeconds)))
        let didChange = abs(clamped - playheadSeconds) > (1.0 / 240.0)
        seekPlayerAndFocusViewport(to: clamped, focusViewport: true)
        if didChange {
            springAnimateVisualPlayhead(to: clamped)
        } else {
            syncVisualPlayheadImmediately(clamped)
        }
    }

    private func seekPlayerAndFocusViewport(to time: Double, focusViewport: Bool = true) {
        let clamped = max(0, min(time, max(playerDurationSeconds, sourcePresentation.sourceDurationSeconds)))
        stopManualViewportPan()
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
            runtime.isViewportManuallyControlled = true
        } else {
            updateViewportForPlayhead(shouldFollow: true)
        }
    }

    private func jumpPlayback(by seconds: Double) {
        seekPlayer(to: playheadSeconds + seconds)
    }

    private func syncClipTranscriptSidebarTimeIfNeeded(_ time: Double, force: Bool = false) {
        guard shouldDriveClipTranscriptSidebarTime else { return }

        let clamped = max(0, min(time, max(playerDurationSeconds, sourcePresentation.sourceDurationSeconds)))
        let now = CACurrentMediaTime()
        let isPlaybackDriven = player.rate != 0 && !isPlayheadDragActive
        let minimumPlaybackInterval = 1.0 / 12.0

        if force || !isPlaybackDriven {
            clipTranscriptSidebarTimeSeconds = clamped
            runtime.lastTranscriptSidebarPlaybackUpdateTimestamp = now
            return
        }

        let timeDelta = abs(clamped - clipTranscriptSidebarTimeSeconds)
        if timeDelta >= 0.20 || (now - runtime.lastTranscriptSidebarPlaybackUpdateTimestamp) >= minimumPlaybackInterval {
            clipTranscriptSidebarTimeSeconds = clamped
            runtime.lastTranscriptSidebarPlaybackUpdateTimestamp = now
        }
    }

    private func togglePlayback() {
        clearSelectionPlaybackState()
        if player.rate != 0 {
            player.pause()
            syncSharedPlayheadStateIfNeeded(playheadSeconds, force: true, updateAlignment: true)
            syncClipTranscriptSidebarTimeIfNeeded(playheadSeconds, force: true)
        } else {
            player.playImmediately(atRate: 1.0)
        }
    }

    private func playSelectionOnly() {
        guard model.clipDurationSeconds > 0 else {
            NSSound.beep()
            return
        }

        let selectionStart = max(0, min(clip.clipStartSeconds, max(playerDurationSeconds, sourcePresentation.sourceDurationSeconds)))
        let selectionEnd = max(selectionStart + 0.001, min(clip.clipEndSeconds, max(playerDurationSeconds, sourcePresentation.sourceDurationSeconds)))

        if player.rate != 0, runtime.selectionPlaybackEndSeconds != nil {
            player.pause()
            syncSharedPlayheadStateIfNeeded(playheadSeconds, force: true, updateAlignment: true)
            clearSelectionPlaybackState()
            return
        }

        installSelectionPlaybackBoundaryObserver(endSeconds: selectionEnd)
        seekPlayer(to: selectionStart)
        player.playImmediately(atRate: 1.0)
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
        clearSelectionPlaybackState()
        if player.rate != 0 {
            player.pause()
            syncClipTranscriptSidebarTimeIfNeeded(playheadSeconds, force: true)
        }
    }

    private func navigateToMarker(previous: Bool) {
        let epsilon = 1.0 / 240.0
        var points = clip.captureTimelineMarkers.map(\.seconds)
        points.append(clip.clipStartSeconds)
        points.append(clip.clipEndSeconds)
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
            clip.highlightedClipBoundary = nil
        } else {
            clip.highlightedCaptureTimelineMarkerID = nil
            model.highlightBoundaryIfNeeded(near: target, clipStart: clip.clipStartSeconds, clipEnd: clip.clipEndSeconds)
        }
    }

    private var totalDurationSeconds: Double {
        max(0.001, max(playerDurationSeconds, sourcePresentation.sourceDurationSeconds))
    }

    private var zoomedWindowDuration: Double {
        max(0.25, totalDurationSeconds / max(1.0, timelineZoom))
    }

    private var deadZonePaddingSeconds: Double {
        // Keep 90% of the viewport as a no-pan zone to reduce disorienting jumps.
        max(0, zoomedWindowDuration * 0.05)
    }

    private var markerSnapToleranceSeconds: Double {
        let width = max(1, runtime.timelineInteractiveWidth)
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
        stopManualViewportPan()
        withAnimation(.easeOut(duration: 0.22)) {
            viewportStartSeconds = clamped
        }
    }

    private func stopManualViewportPan() {
        runtime.manualViewportPanTask?.cancel()
        runtime.manualViewportPanTask = nil
        runtime.manualViewportPanTargetStartSeconds = nil
    }

    private func startManualViewportPanLoopIfNeeded() {
        guard runtime.manualViewportPanTask == nil else { return }
        runtime.manualViewportPanTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let target = runtime.manualViewportPanTargetStartSeconds else { break }
                let current = viewportStartSeconds
                let delta = target - current
                let secondsPerPixel = zoomedWindowDuration / Double(max(1, runtime.timelineInteractiveWidth))
                let settleThreshold = max(secondsPerPixel * 0.35, 0.0001)
                let responseFactor = min(max(runtime.manualViewportPanResponseFactor, 0.05), 0.95)

                if abs(delta) <= settleThreshold {
                    viewportStartSeconds = target
                    runtime.manualViewportPanTargetStartSeconds = nil
                    break
                }

                viewportStartSeconds = clampedViewportStart(current + (delta * responseFactor))
                try? await Task.sleep(nanoseconds: 16_000_000)
            }

            runtime.manualViewportPanTask = nil
        }
    }

    private func smoothlyPanViewport(toStart targetStart: Double, responseFactor: Double) {
        let target = clampedViewportStart(targetStart)
        let baseStart = runtime.manualViewportPanTargetStartSeconds ?? viewportStartSeconds
        guard abs(target - baseStart) > (zoomedWindowDuration / 2500.0) else { return }
        runtime.isViewportManuallyControlled = true
        runtime.manualViewportPanResponseFactor = responseFactor
        runtime.manualViewportPanTargetStartSeconds = target
        startManualViewportPanLoopIfNeeded()
    }

    private func updateViewportForPlayhead(shouldFollow: Bool) {
        if timelineZoom <= 1 {
            if abs(viewportStartSeconds) > 0.000_001 {
                stopManualViewportPan()
                viewportStartSeconds = 0
            }
            if runtime.isViewportManuallyControlled {
                runtime.isViewportManuallyControlled = false
            }
            return
        }

        let window = zoomedWindowDuration
        var start = clampedViewportStart(viewportStartSeconds)
        guard shouldFollow else {
            if abs(viewportStartSeconds - start) > 0.000_001 {
                stopManualViewportPan()
                viewportStartSeconds = start
            }
            return
        }

        let end = start + window
        // Follow mode: keep playhead visible and recenter if it leaves the viewport.
        if playheadSeconds < start || playheadSeconds > end {
            if player.rate != 0 {
                let pageRevealFraction = playheadSeconds > end ? 0.25 : 0.75
                animateViewportRecenter(to: playheadSeconds - (window * pageRevealFraction))
            } else {
                animateViewportRecenter(to: playheadSeconds - (window / 2))
            }
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
            stopManualViewportPan()
            viewportStartSeconds = clamped
        }
    }

    private func panViewport(byPoints points: CGFloat, smoothly: Bool, responseFactor: Double = 0.38) {
        guard timelineZoom > 1 else { return }
        let width = max(1, runtime.timelineInteractiveWidth)
        let secondsPerPoint = zoomedWindowDuration / Double(width)
        let baseStart = smoothly ? (runtime.manualViewportPanTargetStartSeconds ?? viewportStartSeconds) : viewportStartSeconds
        // Natural-feeling pan: swipe left reveals later timeline content.
        let nextStart = clampedViewportStart(baseStart - (Double(points) * secondsPerPoint))
        if abs(nextStart - baseStart) < (zoomedWindowDuration / 2500.0) {
            return
        }
        runtime.isViewportManuallyControlled = true
        if smoothly {
            smoothlyPanViewport(toStart: nextStart, responseFactor: responseFactor)
        } else {
            stopManualViewportPan()
            viewportStartSeconds = nextStart
        }
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
            // Edge auto-pan should feel continuous, but still track the drag closely.
            panViewport(byPoints: panPoints, smoothly: true, responseFactor: 0.72)
            return true
        }
        stopManualViewportPan()
        return false
    }

    private func timeForPlayheadDragLocation(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return playheadSeconds }
        let ratio = min(max(0, x / width), 1.0)
        let duration = max(0.0001, visibleEndSeconds - visibleStartSeconds)
        return min(totalDurationSeconds, max(0, visibleStartSeconds + (Double(ratio) * duration)))
    }

    private func startPlayheadDragAutoPanLoopIfNeeded() {
        guard runtime.playheadDragAutoPanTask == nil else { return }
        runtime.playheadDragAutoPanTask = Task { @MainActor in
            while !Task.isCancelled && isPlayheadDragActive {
                guard let x = runtime.playheadDragLocationX, runtime.playheadDragWidth > 0 else {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    continue
                }
                if autoPanViewportIfNeededForPlayheadDrag(x: x, width: runtime.playheadDragWidth) {
                    seekPlayerInteractive(to: timeForPlayheadDragLocation(x: x, width: runtime.playheadDragWidth))
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func stopPlayheadDragAutoPanLoop() {
        runtime.playheadDragAutoPanTask?.cancel()
        runtime.playheadDragAutoPanTask = nil
    }

    private func updatePlayheadDragLocation(_ x: CGFloat, width: CGFloat) {
        runtime.playheadDragLocationX = x
        runtime.playheadDragWidth = width
    }

    private func setPlayheadDragActive(_ active: Bool) {
        isPlayheadDragActive = active
        model.setInteractiveTimelineScrubbing(active)
        if active {
            stopManualViewportPan()
            runtime.lastInteractiveSeekCommitTimestamp = 0
            runtime.lastInteractiveReadoutSyncTimestamp = 0
            startPlayheadDragAutoPanLoopIfNeeded()
        } else {
            stopPlayheadDragAutoPanLoop()
            stopManualViewportPan()
            if let x = runtime.playheadDragLocationX, runtime.playheadDragWidth > 0 {
                seekPlayerInteractive(to: timeForPlayheadDragLocation(x: x, width: runtime.playheadDragWidth), forceCommit: true)
            }
            if let dragVisualPlayheadSeconds {
                playheadSeconds = dragVisualPlayheadSeconds
                syncSharedPlayheadStateIfNeeded(dragVisualPlayheadSeconds, force: true)
                syncVisualPlayheadImmediately(dragVisualPlayheadSeconds)
            }
            dragVisualPlayheadSeconds = nil
            runtime.lastInteractiveSeekSeconds = -1
            runtime.playheadDragLocationX = nil
            runtime.playheadDragWidth = 0
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
        let baseStart = runtime.manualViewportPanTargetStartSeconds ?? viewportStartSeconds
        let nextStart = clampedViewportStart(baseStart + delta)
        smoothlyPanViewport(toStart: nextStart, responseFactor: 0.55)
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
        if isPlayheadDragActive && !force {
            return
        }
        let now = CACurrentMediaTime()
        let syncInterval = 1.0 / 20.0
        guard force || (now - runtime.lastSharedPlayheadSyncTimestamp) >= syncInterval else { return }
        if abs(clip.clipPlayheadSeconds - seconds) > (1.0 / 240.0) {
            PlayheadDiagnostics.shared.noteModelWrite("shared_playhead_write")
            clip.clipPlayheadSeconds = seconds
        }
        if updateAlignment {
            model.selectTimelineMarkerIfAligned(near: seconds)
        }
        runtime.lastSharedPlayheadSyncTimestamp = now
    }

    private func registerBenchmarkDriverIfNeeded() {
        guard PlayheadDiagnostics.shared.isEnabled else { return }
        PlayheadBenchmarkCoordinator.shared.register(
            driver: .init(
                isReady: { isBenchmarkReady && runtime.waveformHostView != nil },
                maxZoomIndex: { max(0, allowedTimelineZoomLevels.count - 1) },
                setZoomIndex: { index in
                    setTimelineZoomIndex(index)
                },
                beginScrubAtRatio: { ratio in
                    let width = max(1, runtime.waveformHostView?.bounds.width ?? runtime.timelineInteractiveWidth)
                    let x = min(max(0, CGFloat(ratio) * width), width)
                    let target = timeForPlayheadDragLocation(x: x, width: width)
                    if let hostView = runtime.waveformHostView {
                        hostView.beginBenchmarkPlayheadDrag(atX: x)
                    } else {
                        PlayheadDiagnostics.shared.noteScrubInput(source: "benchmark_begin", seconds: target)
                        setPlayheadDragActive(true)
                        updatePlayheadDragLocation(x, width: width)
                        seekPlayerInteractive(to: target, forceCommit: true)
                    }
                },
                updateScrubToRatio: { ratio in
                    let width = max(1, runtime.waveformHostView?.bounds.width ?? runtime.timelineInteractiveWidth)
                    let x = min(max(0, CGFloat(ratio) * width), width)
                    let target = timeForPlayheadDragLocation(x: x, width: width)
                    if let hostView = runtime.waveformHostView {
                        hostView.updateBenchmarkPlayheadDrag(atX: x)
                    } else {
                        PlayheadDiagnostics.shared.noteScrubInput(source: "benchmark_step", seconds: target)
                        updatePlayheadDragLocation(x, width: width)
                        seekPlayerInteractive(to: target)
                    }
                },
                endScrubAtRatio: { ratio in
                    let width = max(1, runtime.waveformHostView?.bounds.width ?? runtime.timelineInteractiveWidth)
                    let x = min(max(0, CGFloat(ratio) * width), width)
                    let target = timeForPlayheadDragLocation(x: x, width: width)
                    if let hostView = runtime.waveformHostView {
                        hostView.endBenchmarkPlayheadDrag(atX: x)
                    } else {
                        PlayheadDiagnostics.shared.noteScrubInput(source: "benchmark_end", seconds: target)
                        updatePlayheadDragLocation(x, width: width)
                        setPlayheadDragActive(false)
                    }
                },
                setTranscriptStressRate: { rate in
                    if let rate, rate > 0 {
                        model.startBenchmarkTranscriptPreviewStress(ratePerSecond: rate)
                    } else {
                        model.stopBenchmarkTranscriptPreviewStress()
                    }
                }
            )
        )
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
        guard runtime.keyMonitor == nil else { return }
        runtime.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard runtime.clipWindow?.isKeyWindow == true else { return event }

            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let rawChars = event.characters ?? ""
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasDisallowedModifier = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)

            if flags.contains(.command) && flags.contains(.option) && !flags.contains(.control) && !flags.contains(.shift) {
                if chars == "s",
                   sourcePresentation.sourceURL != nil,
                   sourcePresentation.hasVideoTrack {
                    model.captureFrame(at: effectivePlayheadSeconds())
                    return nil
                }
            }

            if NSApp.keyWindow?.firstResponder is NSTextView {
                return event
            }

            if flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) && !flags.contains(.shift) {
                if event.keyCode == 49 {
                    playSelectionOnly()
                    return nil
                }
            }

            if flags.isDisjoint(with: [.command, .option, .control, .shift]) {
                if rawChars == " " {
                    togglePlayback()
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
                if chars == "a" {
                    model.resetClipRange(undoManager: undoManager)
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
                let fps = max(1.0, sourcePresentation.sourceInfo?.frameRate ?? 30.0)
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
                let fps = max(1.0, sourcePresentation.sourceInfo?.frameRate ?? 30.0)
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
                    seekPlayer(to: clip.clipStartSeconds)
                    return nil
                }
                if chars == "m" {
                    model.addTimelineMarker(at: effectivePlayheadSeconds(), undoManager: undoManager)
                    return nil
                }
            }

            let hasShift = flags.contains(.shift)
            guard hasShift && !hasDisallowedModifier else { return event }

            let fps = max(1.0, sourcePresentation.sourceInfo?.frameRate ?? 30.0)
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
        guard runtime.scrollMonitor == nil else { return }
        runtime.scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            guard runtime.clipWindow?.isKeyWindow == true else { return event }
            guard runtime.isTimelineHovered, timelineZoom > 1 else { return event }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let usesHorizontalModifier = flags.contains(.shift) || flags.contains(.command)

            let sourceDelta: CGFloat
            if abs(dx) >= 0.1 {
                sourceDelta = dx
            } else if usesHorizontalModifier && abs(dy) >= 0.1 {
                sourceDelta = dy
            } else {
                return event
            }

            // Match typical app behavior more closely:
            // precise devices already report point-like deltas, while wheel mice report line steps.
            let panPoints = event.hasPreciseScrollingDeltas ? sourceDelta : (sourceDelta * 14.0)

            // Ignore tiny jitter deltas to reduce needless redraw churn.
            if abs(panPoints) < (event.hasPreciseScrollingDeltas ? 0.45 : 1.0) {
                return nil
            }

            panViewport(byPoints: panPoints, smoothly: true, responseFactor: 0.48)
            return nil
        }
    }

    private func installFlagsMonitor() {
        guard runtime.flagsMonitor == nil else { return }
        runtime.flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            guard runtime.clipWindow?.isKeyWindow == true else { return event }
            isOptionKeyPressed = event.modifierFlags.contains(.option)
            return event
        }
    }

    private func installMouseDownMonitor() {
        guard runtime.mouseDownMonitor == nil else { return }
        runtime.mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard runtime.clipWindow?.isKeyWindow == true else { return event }
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
        guard timelineZoom > 1, runtime.isWaveformHovered, runtime.isMiddleMousePanning else {
            NSCursor.arrow.set()
            return
        }
        NSCursor.closedHand.set()
    }

    private func installMiddleMousePanMonitor() {
        guard runtime.middleMousePanMonitor == nil else { return }
        runtime.middleMousePanMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseDragged, .otherMouseUp]) { event in
            guard runtime.clipWindow?.isKeyWindow == true else { return event }
            guard event.buttonNumber == 2 else { return event }

            switch event.type {
            case .otherMouseDown:
                guard runtime.isWaveformHovered, timelineZoom > 1 else { return event }
                runtime.isMiddleMousePanning = true
                runtime.middleMousePanLastWindowX = event.locationInWindow.x
                updateTimelineCursor()
                return nil
            case .otherMouseDragged:
                guard runtime.isMiddleMousePanning else { return event }
                let currentX = event.locationInWindow.x
                let lastX = runtime.middleMousePanLastWindowX ?? currentX
                let deltaX = currentX - lastX
                runtime.middleMousePanLastWindowX = currentX
                panViewport(byPoints: deltaX, smoothly: true)
                return nil
            case .otherMouseUp:
                guard runtime.isMiddleMousePanning else { return event }
                runtime.isMiddleMousePanning = false
                runtime.middleMousePanLastWindowX = nil
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
        if let keyMonitor = runtime.keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            runtime.keyMonitor = nil
        }
        if let flagsMonitor = runtime.flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            runtime.flagsMonitor = nil
        }
        if let scrollMonitor = runtime.scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            runtime.scrollMonitor = nil
        }
        if let mouseDownMonitor = runtime.mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            runtime.mouseDownMonitor = nil
        }
        if let middleMousePanMonitor = runtime.middleMousePanMonitor {
            NSEvent.removeMonitor(middleMousePanMonitor)
            runtime.middleMousePanMonitor = nil
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
        !isCompactLayout && sourcePresentation.hasAudioTrack
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

    private func bestFitTranscriptSidebarWidth(maximumSidebarWidth: CGFloat) -> CGFloat {
        let rows = sourcePresentation.transcriptSegments.map { segment in
            TranscriptDisplayRow(
                id: segment.id,
                start: segment.start,
                startLabel: formatSeconds(segment.start),
                text: segment.text,
                normalizedText: normalizedTranscriptSearchText(segment.text)
            )
        }

        guard !rows.isEmpty else {
            return min(clipTranscriptSidebarMinWidth, maximumSidebarWidth)
        }

        let documentWidth = exactTranscriptTableDocumentWidth(for: rows, fontSize: 13)
        let sidebarPadding: CGFloat = 24
        let baseHeadroom: CGFloat = 56
        let legacyScrollerAllowance: CGFloat
        if NSScroller.preferredScrollerStyle == .legacy {
            legacyScrollerAllowance = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) + 18
        } else {
            legacyScrollerAllowance = 0
        }
        let desiredWidth = documentWidth + sidebarPadding + baseHeadroom + legacyScrollerAllowance
        let cappedMaximum = min(clipTranscriptSidebarMaxWidth, maximumSidebarWidth)
        return min(max(desiredWidth, clipTranscriptSidebarMinWidth), cappedMaximum)
    }

    private func playTranscript(from seconds: Double) {
        seekPlayerAndFocusViewport(to: seconds, focusViewport: true)
        springAnimateVisualPlayhead(to: seconds)
        player.playImmediately(atRate: 1.0)
    }

    private var currentPlayerAspectRatio: CGFloat {
        if let resolution = sourcePresentation.sourceInfo?.resolution {
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
            ClipPlayerStageSection(
                player: player,
                currentPlayerHeight: currentPlayerHeight,
                preferredPlayerDisplayWidth: preferredPlayerDisplayWidth,
                showsClipTranscriptSidebar: showsClipTranscriptSidebar,
                canShowClipTranscriptSidebar: canShowClipTranscriptSidebar,
                clipTranscriptSidebarWidth: clipTranscriptSidebarWidth,
                transcriptSegments: sourcePresentation.transcriptSegments,
                transcriptStatusText: sourcePresentation.transcriptStatusText,
                canGenerateTranscript: model.canGenerateTranscript,
                isGeneratingTranscript: sourcePresentation.isGeneratingTranscript,
                hasAudioTrack: sourcePresentation.hasAudioTrack,
                currentTimeSeconds: clipTranscriptSidebarTimeSeconds,
                isPlaying: player.rate != 0,
                isScrubbing: isPlayheadDragActive,
                reduceTransparency: reduceTransparency,
                focusSearchFieldToken: clipTranscriptSearchFocusToken,
                isMiddleMousePanning: runtime.isMiddleMousePanning,
                onDismissTimecodeFieldFocus: dismissTimecodeFieldFocus,
                onAutoFitTranscriptSidebar: { maximumSidebarWidth in
                    let fittedWidth = bestFitTranscriptSidebarWidth(maximumSidebarWidth: maximumSidebarWidth)
                    storedTranscriptSidebarWidth = Double(fittedWidth)
                    liveTranscriptSidebarWidth = nil
                    runtime.transcriptSidebarResizeStartWidth = nil
                    runtime.transcriptSidebarResizeStartGlobalX = nil
                },
                onTranscriptSidebarResizeChanged: { value in
                    if runtime.transcriptSidebarResizeStartWidth == nil {
                        runtime.transcriptSidebarResizeStartWidth = clipTranscriptSidebarWidth
                        runtime.transcriptSidebarResizeStartGlobalX = value.startLocation.x
                    }
                    let base = runtime.transcriptSidebarResizeStartWidth ?? clipTranscriptSidebarWidth
                    let startX = runtime.transcriptSidebarResizeStartGlobalX ?? value.startLocation.x
                    let deltaX = value.location.x - startX
                    liveTranscriptSidebarWidth = clampedTranscriptSidebarWidth(base - deltaX)
                },
                onTranscriptSidebarResizeEnded: {
                    if let liveTranscriptSidebarWidth {
                        storedTranscriptSidebarWidth = Double(clampedTranscriptSidebarWidth(liveTranscriptSidebarWidth))
                    }
                    liveTranscriptSidebarWidth = nil
                    runtime.transcriptSidebarResizeStartWidth = nil
                    runtime.transcriptSidebarResizeStartGlobalX = nil
                },
                onGenerateTranscript: {
                    model.generateTranscript()
                },
                onExportTranscript: {
                    model.exportTranscriptFromInspect()
                },
                onSeekToTranscriptTime: { seconds in
                    seekPlayerAndFocusViewport(to: seconds, focusViewport: true)
                    springAnimateVisualPlayhead(to: seconds)
                },
                onPlayTranscriptFromTime: { seconds in
                    playTranscript(from: seconds)
                },
                onCloseTranscript: {
                    storedTranscriptSidebarVisible = false
                },
                onShowTranscript: {
                    storedTranscriptSidebarVisible = true
                }
            )
            .equatable()

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
                } else if !runtime.isMiddleMousePanning {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if runtime.playerResizeStartHeight == nil {
                            let base = storedPlayerHeight > 0 ? CGFloat(storedPlayerHeight) : playerDefaultHeight
                            runtime.playerResizeStartHeight = clampedPlayerHeight(base)
                            runtime.playerResizeStartGlobalY = value.startLocation.y
                        }
                        let base = runtime.playerResizeStartHeight ?? currentPlayerHeight
                        let startY = runtime.playerResizeStartGlobalY ?? value.startLocation.y
                        let deltaY = value.location.y - startY
                        livePlayerHeight = clampedPlayerHeight(base + deltaY)
                    }
                    .onEnded { _ in
                        if let livePlayerHeight {
                            storedPlayerHeight = Double(clampedPlayerHeight(livePlayerHeight))
                        }
                        livePlayerHeight = nil
                        runtime.playerResizeStartHeight = nil
                        runtime.playerResizeStartGlobalY = nil
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
                hasVideoTrack: sourcePresentation.hasVideoTrack,
                playheadSeconds: displayedPlayheadSeconds,
                totalDurationSeconds: max(playerDurationSeconds, sourcePresentation.sourceDurationSeconds),
                playheadCopyFlash: playheadCopyFlash,
                compactZoomDisplayText: compactPlayerZoomDisplayText,
                timelineZoomLevelCount: allowedTimelineZoomLevels.count,
                onCopyPlayheadTimecode: copyPlayheadTimecode,
                onJumpToStart: {
                    seekPlayer(to: clip.clipStartSeconds)
                    springAnimateVisualPlayhead(to: clip.clipStartSeconds)
                },
                onJumpToEnd: {
                    seekPlayer(to: clip.clipEndSeconds)
                    springAnimateVisualPlayhead(to: clip.clipEndSeconds)
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
            .equatable()
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

    private var shouldDriveClipTranscriptSidebarTime: Bool {
        showsClipTranscriptSidebar && sourcePresentation.hasAudioTrack
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
            clipStartSeconds: clip.clipStartSeconds,
            clipEndSeconds: clip.clipEndSeconds,
            captureMarkers: clip.captureTimelineMarkers
        ) { newStart in
            stopManualViewportPan()
            viewportStartSeconds = clampedViewportStart(newStart)
            runtime.isViewportManuallyControlled = true
        } content: {
            selectionSection
        }
    }

    private var selectionSection: some View {
        ClipSelectionPanel(
            player: player,
            sourceSessionID: sourcePresentation.sourceSessionID,
            clipStartSeconds: displayedClipStartSeconds,
            clipEndSeconds: displayedClipEndSeconds,
            clipDurationSeconds: model.clipDurationSeconds,
            hasVideoTrack: sourcePresentation.hasVideoTrack,
            timelinePanelHeight: timelinePanelHeight,
            thumbnailStripHeight: thumbnailStripHeight,
            clipStartText: $clipTimelinePresentation.clipStartText,
            clipEndText: $clipTimelinePresentation.clipEndText,
            onCommitClipStartText: { model.commitClipStartText(undoManager: undoManager) },
            onCommitClipEndText: { model.commitClipEndText(undoManager: undoManager) },
            isCompactLayout: isCompactLayout,
            reduceTransparency: reduceTransparency,
            isWaveformLoading: isWaveformLoading,
            waveformSamples: waveformSamples,
            thumbnailTiles: thumbnailTiles,
            thumbnailTilesRevision: thumbnailTilesRevision,
            thumbnailStripImage: thumbnailStripImage,
            thumbnailStripRevision: thumbnailStripRevision,
            thumbnailStripShouldCrossfade: thumbnailStripShouldCrossfade,
            isThumbnailStripLoading: isThumbnailStripLoading,
            thumbnailStripSourceStartSeconds: thumbnailStripSourceStartSeconds,
            thumbnailStripSourceEndSeconds: thumbnailStripSourceEndSeconds,
            thumbnailStripSourceVisibleDurationSeconds: thumbnailStripSourceVisibleDurationSeconds,
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
            captureMarkers: clip.captureTimelineMarkers,
            highlightedMarkerID: clip.highlightedCaptureTimelineMarkerID,
            highlightedClipBoundary: clip.highlightedClipBoundary,
            captureFrameFlashToken: clip.captureFrameFlashToken,
            quickExportFlashToken: clip.quickExportFlashToken,
            onTimelineWidthChanged: { width in
                runtime.timelineInteractiveWidth = width
                timelineInteractiveWidth = width
            },
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
            onClipBoundaryDragStateChanged: { isActive in
                setClipBoundaryDragActive(isActive)
            },
            onSetStart: { previewClipStartDuringDrag($0) },
            onSetEnd: { previewClipEndDuringDrag($0) },
            onWaveformHoverChanged: { hovering in
                runtime.isWaveformHovered = hovering
                if !hovering {
                    runtime.timelinePointerSeconds = nil
                }
                if !runtime.isMiddleMousePanning {
                    updateTimelineCursor()
                }
            },
            onWaveformPointerTimeChanged: { runtime.timelinePointerSeconds = $0 },
            onWaveformHostViewAvailable: { runtime.waveformHostView = $0 },
            onTimelineHoverChanged: { hovering in
                runtime.isTimelineHovered = hovering
                if !runtime.isMiddleMousePanning {
                    NSCursor.arrow.set()
                }
            },
            onCopyPlayheadTimecode: copyPlayheadTimecode,
            onJumpToStart: {
                seekPlayer(to: clip.clipStartSeconds)
                springAnimateVisualPlayhead(to: clip.clipStartSeconds)
            },
            onJumpToEnd: {
                seekPlayer(to: clip.clipEndSeconds)
                springAnimateVisualPlayhead(to: clip.clipEndSeconds)
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
        .equatable()
    }

    private var clipBaseContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if sourcePresentation.sourceURL != nil {
                clipPlayerSection
                timelineControlsSection
                outputSection
                Spacer()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissTimecodeFieldFocus()
                    }
            } else {
                emptySourceImportView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 40)
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
        .sheet(
            isPresented: Binding(
                get: { model.isURLImportSheetPresented },
                set: { model.isURLImportSheetPresented = $0 }
            )
        ) {
            urlImportSheetView
        }
    }

    private var emptySourceImportView: some View {
        ClipEmptySourceView(
            emptyStateURLText: $emptyStateURLText,
            isDropTargeted: $isEmptyDropTargeted,
            urlDownloadPreset: Binding(
                get: { model.urlDownloadPreset },
                set: { model.urlDownloadPreset = $0 }
            ),
            urlDownloadSaveMode: Binding(
                get: { model.urlDownloadSaveLocationMode },
                set: { model.urlDownloadSaveLocationMode = $0 }
            ),
            customURLDownloadDirectoryPath: Binding(
                get: { model.customURLDownloadDirectoryPath },
                set: { model.customURLDownloadDirectoryPath = $0 }
            ),
            urlDownloadAuthenticationMode: Binding(
                get: { model.urlDownloadAuthenticationMode },
                set: { model.urlDownloadAuthenticationMode = $0 }
            ),
            urlDownloadBrowserCookiesSource: Binding(
                get: { model.urlDownloadBrowserCookiesSource },
                set: { model.urlDownloadBrowserCookiesSource = $0 }
            ),
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
                    customFolderPath: model.customURLDownloadDirectoryPath,
                    authenticationMode: model.urlDownloadAuthenticationMode,
                    browserCookiesSource: model.urlDownloadBrowserCookiesSource
                )
            },
            onChooseCustomFolder: {
                model.chooseCustomURLDownloadDirectory()
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

    private func prepareURLImportSheetDefaults(prefilledURLText: String? = nil) {
        importURLText = prefilledURLText ?? ""
        importURLPreset = model.urlDownloadPreset
        importURLSaveMode = model.urlDownloadSaveLocationMode
        importCustomFolderPath = model.customURLDownloadDirectoryPath
        importURLAuthenticationMode = model.urlDownloadAuthenticationMode
        importURLBrowserCookiesSource = model.urlDownloadBrowserCookiesSource
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
            customFolderPath: importCustomFolderPath,
            authenticationMode: importURLAuthenticationMode,
            browserCookiesSource: importURLBrowserCookiesSource
        )
    }

    private var urlImportSheetView: some View {
        ClipURLImportSheetView(
            importURLText: $importURLText,
            importURLPreset: $importURLPreset,
            importURLSaveMode: $importURLSaveMode,
            importCustomFolderPath: $importCustomFolderPath,
            importURLAuthenticationMode: $importURLAuthenticationMode,
            importURLBrowserCookiesSource: $importURLBrowserCookiesSource,
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
            if PlayheadDiagnostics.shared.isEnabled {
                PlayheadDiagnostics.shared.writeProgress(stage: "clip_view_appeared", scenario: nil)
            }
            resetPlayerHeightToDefaultIfNeeded()
            syncDisplayedClipRangeImmediately()
            loadPlayerItem()
            installPlayerTimeObserverIfNeeded()
            installKeyMonitor()
            installFlagsMonitor()
            installScrollMonitor()
            installMouseDownMonitor()
            installMiddleMousePanMonitor()
            scheduleThumbnailStripGeneration(immediate: true)
            if shouldDriveClipTranscriptSidebarTime {
                syncClipTranscriptSidebarTimeIfNeeded(displayedPlayheadSeconds, force: true)
            }
            registerBenchmarkDriverIfNeeded()
        }

        let step2 = step1.onChange(of: sourcePresentation.sourceURL?.path) { _ in
            clearThumbnailStrip()
            loadPlayerItem()
            scheduleThumbnailStripGeneration(immediate: true)
            registerBenchmarkDriverIfNeeded()
        }

        let step3 = step2.onChange(of: model.clipEncodingMode) { mode in
            if !sourcePresentation.hasVideoTrack && mode != .audioOnly {
                model.clipEncodingMode = .audioOnly
                return
            }
            if mode == .fast && !model.selectedClipFormat.supportsPassthrough {
                model.selectedClipFormat = .mp4
            }
        }

        let step4 = step3
            .onChange(of: clip.clipStartSeconds) { _ in
                guard !isClipBoundaryDragActive else { return }
                syncDisplayedClipRangeImmediately()
            }
            .onChange(of: clip.clipEndSeconds) { _ in
                guard !isClipBoundaryDragActive else { return }
                syncDisplayedClipRangeImmediately()
            }
            .onChange(of: displayedPlayheadSeconds) { newValue in
                guard shouldDriveClipTranscriptSidebarTime, !isPlayheadDragActive else { return }
                syncClipTranscriptSidebarTimeIfNeeded(newValue)
            }
            .onChange(of: isPlayheadDragActive) { active in
                if shouldDriveClipTranscriptSidebarTime, !active {
                    syncClipTranscriptSidebarTimeIfNeeded(displayedPlayheadSeconds, force: true)
                }
            }
            .onChange(of: storedTranscriptSidebarVisible) { isVisible in
                if isVisible && sourcePresentation.hasAudioTrack {
                    syncClipTranscriptSidebarTimeIfNeeded(displayedPlayheadSeconds, force: true)
                }
            }
            .onChange(of: model.selectedClipFormat) { format in
                if format == .webm {
                    model.clipAdvancedVideoCodec = .h264
                }
            }
            .onChange(of: timelineInteractiveWidth) { _ in
                scheduleThumbnailStripGeneration()
                registerBenchmarkDriverIfNeeded()
            }
            .onChange(of: isWaveformLoading) { _ in
                registerBenchmarkDriverIfNeeded()
            }
            .onChange(of: visibleStartSeconds) { _ in
                scheduleThumbnailStripGeneration()
            }
            .onChange(of: visibleEndSeconds) { _ in
                scheduleThumbnailStripGeneration()
            }
            .onChange(of: sourcePresentation.hasVideoTrack) { _ in
                scheduleThumbnailStripGeneration(immediate: true)
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
                seekPlayer(to: clip.clipStartSeconds)
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
            runtime.waveformTask?.cancel()
            runtime.thumbnailStripTask?.cancel()
            runtime.thumbnailStripDebounceTask?.cancel()
            stopManualViewportPan()
            stopClipBoundaryVisualSmoothing()
            isClipBoundaryDragActive = false
            activeClipBoundaryDragKind = nil
            syncDisplayedClipRangeImmediately()
            syncSharedPlayheadStateIfNeeded(playheadSeconds, force: true, updateAlignment: true)
            removeKeyMonitor()
            removePlayerTimeObserver()
            isOptionKeyPressed = false
            runtime.isMiddleMousePanning = false
            runtime.middleMousePanLastWindowX = nil
            runtime.isWaveformHovered = false
            stopPlayheadDragAutoPanLoop()
            NSCursor.arrow.set()
            player.pause()
        }
    }

    var body: some View {
        withLifecycleHandlers(clipBaseContent)
            .background(
                WindowAccessor { window in
                    runtime.clipWindow = window
                }
            )
    }
}
