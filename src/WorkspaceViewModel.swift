import SwiftUI
import AppKit
import AVFoundation
import InOutCore
import UniformTypeIdentifiers
import UserNotifications
import Foundation

enum ClipExportQueueStatus: String, Equatable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

struct QueuedClipExport: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let fileName: String
    let summary: String
    let subtitle: String?
    var status: ClipExportQueueStatus
    var message: String?
    var outputURL: URL? = nil
}

enum QueuedJobKind: Equatable {
    case clip(skipSaveDialog: Bool)
    case audioExport
    case analysis
}

@MainActor
final class WorkspaceViewModel: ObservableObject {
    private enum DefaultsKey {
        static let audioBitrateKbps = "prefs.audioBitrateKbps"
        static let defaultClipEncodingMode = "prefs.defaultClipEncodingMode"
        static let advancedClipFilenamePreset = "prefs.advancedClipFilenamePreset"
        static let advancedClipFilenameTemplate = "prefs.advancedClipFilenameTemplate"
        static let jumpIntervalSeconds = "prefs.jumpIntervalSeconds"
        static let completionSound = "prefs.completionSound"
        static let appearance = "prefs.appearance"
        static let silenceMinDurationSeconds = "prefs.silenceMinDurationSeconds"
        static let profanityWords = "prefs.profanityWords"
        static let frameSaveLocationMode = "prefs.frameSaveLocationMode"
        static let customFrameSaveDirectoryPath = "prefs.customFrameSaveDirectoryPath"
        static let burnInCaptionStyle = "prefs.burnInCaptionStyle"
        static let advancedBoostAmount = "prefs.advancedBoostAmount"
        static let estimatedSizeWarningThresholdGB = "prefs.estimatedSizeWarningThresholdGB"
        static let estimatedSizeDangerThresholdGB = "prefs.estimatedSizeDangerThresholdGB"
        static let urlDownloadPreset = "prefs.urlDownloadPreset"
        static let urlDownloadSaveLocationMode = "prefs.urlDownloadSaveLocationMode"
        static let customURLDownloadDirectoryPath = "prefs.customURLDownloadDirectoryPath"
        static let urlDownloadAuthenticationMode = "prefs.urlDownloadAuthenticationMode"
        static let urlDownloadBrowserCookiesSource = "prefs.urlDownloadBrowserCookiesSource"
    }

    @Published var selectedTool: WorkspaceTool = .clip
    let sourcePresentation = SourcePresentationModel()
    let clipTimelinePresentation = ClipTimelinePresentationModel()
    @Published var sourceURL: URL? {
        didSet { sourcePresentation.sourceURL = sourceURL }
    }
    @Published var sourceSessionID = UUID() {
        didSet { sourcePresentation.sourceSessionID = sourceSessionID }
    }
    @Published var analysis: FileAnalysis? {
        didSet { sourcePresentation.analysis = analysis }
    }
    @Published var sourceInfo: SourceMediaInfo? {
        didSet { sourcePresentation.sourceInfo = sourceInfo }
    }
    @Published var transcriptSegments: [TranscriptSegment] = [] {
        didSet { sourcePresentation.transcriptSegments = transcriptSegments }
    }
    @Published var transcriptStatusText: String = "No transcript generated yet." {
        didSet { sourcePresentation.transcriptStatusText = transcriptStatusText }
    }
    @Published var hasCachedTranscript = false {
        didSet { sourcePresentation.hasCachedTranscript = hasCachedTranscript }
    }
    @Published var isGeneratingTranscript = false {
        didSet { sourcePresentation.isGeneratingTranscript = isGeneratingTranscript }
    }

    @Published var isAnalyzing = false {
        didSet {
            updateDockProgressIndicator()
            if oldValue && !isAnalyzing {
                startNextQueuedJobIfPossible()
            }
        }
    }
    let activityPresentation = ActivityPresentationModel()
    var analyzePhaseText = "Preparing analysis"
    @Published var wasCancelled = false

    @Published var selectedAudioFormat: AudioFormat = .mp3
    @Published var defaultAudioBitrateKbps = 128 {
        didSet {
            let clamped = min(max(64, defaultAudioBitrateKbps), 320)
            if clamped != defaultAudioBitrateKbps {
                defaultAudioBitrateKbps = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: DefaultsKey.audioBitrateKbps)
            exportAudioBitrateKbps = clamped
        }
    }
    @Published var exportAudioBitrateKbps = 128
    @Published var isExporting = false {
        didSet {
            updateDockProgressIndicator()
            if oldValue && !isExporting {
                startNextQueuedJobIfPossible()
            }
        }
    }
    @Published var outputURL: URL?
    @Published var queuedJobs: [QueuedClipExport] = []
    @Published var activeQueuedJobID: UUID?
    var captureTimelineMarkers: [CaptureTimelineMarker] {
        get { clipTimelinePresentation.captureTimelineMarkers }
        set { clipTimelinePresentation.captureTimelineMarkers = newValue }
    }

    var highlightedCaptureTimelineMarkerID: UUID? {
        get { clipTimelinePresentation.highlightedCaptureTimelineMarkerID }
        set { clipTimelinePresentation.highlightedCaptureTimelineMarkerID = newValue }
    }

    var highlightedClipBoundary: ClipBoundaryHighlight? {
        get { clipTimelinePresentation.highlightedClipBoundary }
        set { clipTimelinePresentation.highlightedClipBoundary = newValue }
    }

    var captureFrameFlashToken: Int {
        get { clipTimelinePresentation.captureFrameFlashToken }
        set { clipTimelinePresentation.captureFrameFlashToken = newValue }
    }

    var quickExportFlashToken: Int {
        get { clipTimelinePresentation.quickExportFlashToken }
        set { clipTimelinePresentation.quickExportFlashToken = newValue }
    }

    var clipStartSeconds: Double {
        get { clipTimelinePresentation.clipStartSeconds }
        set { clipTimelinePresentation.clipStartSeconds = newValue }
    }

    var clipEndSeconds: Double {
        get { clipTimelinePresentation.clipEndSeconds }
        set { clipTimelinePresentation.clipEndSeconds = newValue }
    }

    var clipPlayheadSeconds: Double {
        get { clipTimelinePresentation.clipPlayheadSeconds }
        set { clipTimelinePresentation.clipPlayheadSeconds = newValue }
    }

    var clipStartText: String {
        get { clipTimelinePresentation.clipStartText }
        set { clipTimelinePresentation.clipStartText = newValue }
    }

    var clipEndText: String {
        get { clipTimelinePresentation.clipEndText }
        set { clipTimelinePresentation.clipEndText = newValue }
    }
    @Published var selectedClipFormat: ClipFormat = .mp4
    @Published var defaultClipEncodingMode: ClipEncodingMode = .fast {
        didSet {
            UserDefaults.standard.set(defaultClipEncodingMode.rawValue, forKey: DefaultsKey.defaultClipEncodingMode)
            if clipEncodingMode != defaultClipEncodingMode {
                clipEncodingMode = defaultClipEncodingMode
            }
        }
    }
    @Published var clipEncodingMode: ClipEncodingMode = .fast
    @Published var clipVideoBitrateMbps: Double = 4.0
    @Published var clipCompatibleSpeedPreset: CompatibleSpeedPreset = .balanced
    @Published var clipCompatibleMaxResolution: CompatibleMaxResolution = .original {
        didSet {
            applySuggestedCompatibleBitrateForResolution()
        }
    }
    @Published var clipAudioBitrateKbps: Int = 128
    @Published var clipAdvancedVideoCodec: AdvancedVideoCodec = .h264
    @Published var clipAdvancedBoostAudio = false
    @Published var clipAdvancedBoostAmount: AdvancedBoostAmount = .db10 {
        didSet {
            UserDefaults.standard.set(clipAdvancedBoostAmount.rawValue, forKey: DefaultsKey.advancedBoostAmount)
        }
    }
    @Published var clipAdvancedAddFadeInOut = false
    @Published var clipAdvancedBurnInCaptions = false
    @Published var clipAdvancedCaptionStyle: BurnInCaptionStyle = .youtube {
        didSet {
            UserDefaults.standard.set(clipAdvancedCaptionStyle.rawValue, forKey: DefaultsKey.burnInCaptionStyle)
        }
    }
    @Published var clipAudioOnlyBoostAudio = false
    @Published var clipAudioOnlyAddFadeInOut = false
    @Published var clipAudioOnlyFormat: ClipAudioOnlyFormat = .mp3
    @Published var advancedClipFilenamePreset: AdvancedFilenamePreset = .sourceClipInOut {
        didSet {
            UserDefaults.standard.set(advancedClipFilenamePreset.rawValue, forKey: DefaultsKey.advancedClipFilenamePreset)
            advancedClipFilenameTemplate = advancedClipFilenamePreset.template
        }
    }
    @Published var advancedClipFilenameTemplate: String = defaultAdvancedClipFilenameTemplate {
        didSet {
            let trimmed = advancedClipFilenameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if advancedClipFilenameTemplate != defaultAdvancedClipFilenameTemplate {
                    advancedClipFilenameTemplate = defaultAdvancedClipFilenameTemplate
                }
                return
            }
            if trimmed != advancedClipFilenameTemplate {
                advancedClipFilenameTemplate = trimmed
                return
            }
            UserDefaults.standard.set(trimmed, forKey: DefaultsKey.advancedClipFilenameTemplate)
        }
    }
    @Published var jumpIntervalSeconds: Int = 5 {
        didSet {
            UserDefaults.standard.set(jumpIntervalSeconds, forKey: DefaultsKey.jumpIntervalSeconds)
        }
    }
    @Published var completionSound: CompletionSound = .crystal {
        didSet {
            UserDefaults.standard.set(completionSound.rawValue, forKey: DefaultsKey.completionSound)
        }
    }
    @Published var appearance: AppAppearance = .dark {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: DefaultsKey.appearance)
        }
    }
    @Published var analyzeBlackFrames = true
    @Published var silenceMinDurationSeconds: Double = defaultMinSilenceDurationSeconds {
        didSet {
            let clamped = min(5.0, max(0.5, silenceMinDurationSeconds))
            if abs(clamped - silenceMinDurationSeconds) > 0.0001 {
                silenceMinDurationSeconds = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: DefaultsKey.silenceMinDurationSeconds)
        }
    }
    @Published var analyzeAudioSilence = true
    @Published var analyzeProfanity = false
    @Published var profanityWordsText: String = defaultProfanityWordsStorageString {
        didSet {
            // Persist raw user text so TextEditor remains fully editable while typing.
            UserDefaults.standard.set(profanityWordsText, forKey: DefaultsKey.profanityWords)
        }
    }
    @Published var frameSaveLocationMode: FrameSaveLocationMode = .askEachTime {
        didSet {
            UserDefaults.standard.set(frameSaveLocationMode.rawValue, forKey: DefaultsKey.frameSaveLocationMode)
        }
    }
    @Published var customFrameSaveDirectoryPath: String = "" {
        didSet {
            UserDefaults.standard.set(customFrameSaveDirectoryPath, forKey: DefaultsKey.customFrameSaveDirectoryPath)
        }
    }
    @Published var urlDownloadPreset: URLDownloadPreset = .compatibleBest {
        didSet {
            UserDefaults.standard.set(urlDownloadPreset.rawValue, forKey: DefaultsKey.urlDownloadPreset)
        }
    }
    @Published var urlDownloadSaveLocationMode: URLDownloadSaveLocationMode = .askEachTime {
        didSet {
            UserDefaults.standard.set(urlDownloadSaveLocationMode.rawValue, forKey: DefaultsKey.urlDownloadSaveLocationMode)
        }
    }
    @Published var customURLDownloadDirectoryPath: String = "" {
        didSet {
            UserDefaults.standard.set(customURLDownloadDirectoryPath, forKey: DefaultsKey.customURLDownloadDirectoryPath)
        }
    }
    @Published var urlDownloadAuthenticationMode: URLDownloadAuthenticationMode = .none {
        didSet {
            UserDefaults.standard.set(urlDownloadAuthenticationMode.rawValue, forKey: DefaultsKey.urlDownloadAuthenticationMode)
        }
    }
    @Published var urlDownloadBrowserCookiesSource: URLDownloadBrowserCookiesSource = .firefox {
        didSet {
            UserDefaults.standard.set(urlDownloadBrowserCookiesSource.rawValue, forKey: DefaultsKey.urlDownloadBrowserCookiesSource)
        }
    }
    @Published var estimatedSizeWarningThresholdGB: Double = 1.0 {
        didSet {
            var clamped = min(max(0.04, estimatedSizeWarningThresholdGB), 20.0)
            if clamped >= estimatedSizeDangerThresholdGB {
                clamped = max(0.04, estimatedSizeDangerThresholdGB - 0.01)
            }
            if abs(clamped - estimatedSizeWarningThresholdGB) > 0.0001 {
                estimatedSizeWarningThresholdGB = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: DefaultsKey.estimatedSizeWarningThresholdGB)
        }
    }
    @Published var estimatedSizeDangerThresholdGB: Double = 2.0 {
        didSet {
            var clamped = min(max(0.05, estimatedSizeDangerThresholdGB), 40.0)
            if clamped <= estimatedSizeWarningThresholdGB {
                clamped = min(40.0, estimatedSizeWarningThresholdGB + 0.01)
            }
            if abs(clamped - estimatedSizeDangerThresholdGB) > 0.0001 {
                estimatedSizeDangerThresholdGB = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: DefaultsKey.estimatedSizeDangerThresholdGB)
        }
    }

    @Published var isURLImportSheetPresented = false
    @Published var downloaderStatusText = "Bundled fallback"
    @Published var downloaderVersionText = "Unavailable"
    @Published var isUpdatingDownloader = false
    @Published var downloaderLastErrorText = ""
    @Published var downloaderCanRollback = false
    @Published var downloaderPreviousVersionText = ""
    @Published var managedPythonVersionText = "Unavailable"
    @Published var downloaderActionStatusText = ""

    var analyzeTask: Task<Void, Never>?
    var exportTask: Task<Void, Never>?
    var captureMarkerHighlightClearTask: Task<Void, Never>?
    var clipBoundaryHighlightClearTask: Task<Void, Never>?
    var transcriptPreviewFlushTask: Task<Void, Never>?
    var benchmarkTranscriptStressTask: Task<Void, Never>?
    var transcriptGenerationRelay: TranscriptGenerationRelay?
    let cancelFlag = CancellationFlag()
    var pendingTranscriptPreviewSegments: [TranscriptSegment] = []
    var isInteractiveTimelineScrubbing = false
    var activeExportSession: AVAssetExportSession?
    var activeProcess: Process?
    var activeClipExportRunToken: UUID?
    private var willTerminateObserver: NSObjectProtocol?
    var exportCancellationRequested = false
    private var notificationAuthRequested = false
    var originalModeDefaultBitrateMbps: Double = 4.0
    struct QueuedClipExportConfig {
        let clipStartSeconds: Double
        let clipEndSeconds: Double
        let clipEncodingMode: ClipEncodingMode
        let selectedClipFormat: ClipFormat
        let clipAudioOnlyFormat: ClipAudioOnlyFormat
        let clipAdvancedVideoCodec: AdvancedVideoCodec
        let clipCompatibleSpeedPreset: CompatibleSpeedPreset
        let clipCompatibleMaxResolution: CompatibleMaxResolution
        let clipVideoBitrateMbps: Double
        let clipAudioBitrateKbps: Int
        let clipAdvancedBoostAudio: Bool
        let clipAdvancedBoostAmount: AdvancedBoostAmount
        let clipAdvancedAddFadeInOut: Bool
        let clipAdvancedBurnInCaptions: Bool
        let clipAdvancedCaptionStyle: BurnInCaptionStyle
        let clipAudioOnlyBoostAudio: Bool
        let clipAudioOnlyAddFadeInOut: Bool
        let destinationURL: URL?
    }
    struct QueuedAudioExportConfig {
        let selectedAudioFormat: AudioFormat
        let exportAudioBitrateKbps: Int
        let destinationURL: URL?
    }
    struct QueuedAnalysisConfig {
        let analyzeBlackFrames: Bool
        let analyzeAudioSilence: Bool
        let analyzeProfanity: Bool
        let silenceMinDurationSeconds: Double
        let profanityWordsText: String
    }
    var queuedJobKinds: [UUID: QueuedJobKind] = [:]
    var queuedClipExportConfigs: [UUID: QueuedClipExportConfig] = [:]
    var queuedAudioExportConfigs: [UUID: QueuedAudioExportConfig] = [:]
    var queuedAnalysisConfigs: [UUID: QueuedAnalysisConfig] = [:]
    var waveformCache: [String: [Double]] = [:]
    var waveformCacheOrder: [String] = []
    var timelineThumbnailStripCache: [String: CGImage] = [:]
    var timelineThumbnailStripCacheOrder: [String] = []
    private let maxWaveformCacheEntries = 6
    private let maxTimelineThumbnailStripCacheEntries = 30
    private let maxActivityConsoleCharacters = 200_000
    private let activityConsoleTrimCharacters = 150_000
    private let activityConsoleFlushIntervalNanos: UInt64 = 100_000_000
    private let analyzeFeedbackFlushIntervalNanos: UInt64 = 100_000_000
    private var pendingActivityConsoleText = ""
    private var activityConsoleFlushTask: Task<Void, Never>?
    var activeAnalyzeFeedbackFileName: String?
    var pendingAnalyzeFeedbackProgress: Double?
    var analyzeFeedbackFlushTask: Task<Void, Never>?
    let downloaderManager = DownloaderManager.shared
    var cachedFFmpegAvailable = false
    var cachedFFprobeAvailable = false
    var cachedYTDLPAvailable = false
    var cachedWhisperCLIAvailable = false
    var cachedWhisperModelAvailable = false
    var cachedWhisperAvailable = false
    init() {
        if PlayheadBenchmarkConfig.shared.enabled {
            PlayheadDiagnostics.shared.writeProgress(stage: "workspace_init_begin", scenario: nil)
        }
        sourcePresentation.sourceURL = sourceURL
        sourcePresentation.sourceSessionID = sourceSessionID
        sourcePresentation.analysis = analysis
        sourcePresentation.sourceInfo = sourceInfo
        sourcePresentation.transcriptSegments = transcriptSegments
        sourcePresentation.transcriptStatusText = transcriptStatusText
        sourcePresentation.hasCachedTranscript = hasCachedTranscript
        sourcePresentation.isGeneratingTranscript = isGeneratingTranscript

        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopCurrentActivity()
            }
        }

        loadPreferences()
        refreshExternalToolAvailabilityCache()
        refreshDownloaderStatus()
        if let mediaPath = Self.commandLineMediaPath() {
            let url = URL(fileURLWithPath: mediaPath)
            if FileManager.default.fileExists(atPath: url.path) {
                if PlayheadBenchmarkConfig.shared.enabled {
                    PlayheadDiagnostics.shared.writeProgress(stage: "cli_source_queued", scenario: nil)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.setSource(url)
                }
            }
        }
        if PlayheadBenchmarkConfig.shared.enabled {
            PlayheadDiagnostics.shared.writeProgress(stage: "workspace_init_complete", scenario: nil)
        }
    }

    deinit {
        if let willTerminateObserver {
            NotificationCenter.default.removeObserver(willTerminateObserver)
        }
        captureMarkerHighlightClearTask?.cancel()
        clipBoundaryHighlightClearTask?.cancel()
        transcriptPreviewFlushTask?.cancel()
        benchmarkTranscriptStressTask?.cancel()
    }

    private func updateDockProgressIndicator() {
        if isAnalyzing {
            DockProgressController.shared.setProgress(analyzeProgress)
            return
        }
        if isExporting {
            DockProgressController.shared.setProgress(exportProgress)
            return
        }
        DockProgressController.shared.clear()
    }

    private static func commandLineMediaPath() -> String? {
        let args = Array(CommandLine.arguments.dropFirst())
        let flagsWithValues: Set<String> = [
            "--playhead-benchmark-output",
            "--playhead-benchmark-progress",
            "--playhead-benchmark-scenarios",
            "--playhead-benchmark-transcript-stress"
        ]
        let flagsWithoutValues: Set<String> = [
            "--playhead-benchmark",
            "--playhead-benchmark-no-exit",
            "--playhead-benchmark-disable-transcript-batching"
        ]

        var index = 0
        while index < args.count {
            let arg = args[index]
            if flagsWithoutValues.contains(arg) {
                index += 1
                continue
            }
            if flagsWithValues.contains(arg) {
                index += 2
                continue
            }
            if FileManager.default.fileExists(atPath: arg) {
                return arg
            }
            index += 1
        }
        return nil
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard

        let savedBitrate = defaults.integer(forKey: DefaultsKey.audioBitrateKbps)
        if savedBitrate > 0 {
            defaultAudioBitrateKbps = min(max(64, savedBitrate), 320)
        }
        exportAudioBitrateKbps = defaultAudioBitrateKbps

        if let rawMode = defaults.string(forKey: DefaultsKey.defaultClipEncodingMode),
           let mode = ClipEncodingMode(rawValue: rawMode) {
            defaultClipEncodingMode = mode
        }
        clipEncodingMode = defaultClipEncodingMode

        if let savedPreset = defaults.string(forKey: DefaultsKey.advancedClipFilenamePreset),
           let preset = AdvancedFilenamePreset(rawValue: savedPreset) {
            advancedClipFilenamePreset = preset
        } else if let savedTemplate = defaults.string(forKey: DefaultsKey.advancedClipFilenameTemplate),
                  let preset = AdvancedFilenamePreset.allCases.first(where: { $0.template == savedTemplate }) {
            advancedClipFilenamePreset = preset
        } else {
            advancedClipFilenameTemplate = advancedClipFilenamePreset.template
        }

        let savedJump = defaults.integer(forKey: DefaultsKey.jumpIntervalSeconds)
        if savedJump > 0 {
            jumpIntervalSeconds = min(max(1, savedJump), 30)
        }

        if let rawSound = defaults.string(forKey: DefaultsKey.completionSound),
           let sound = CompletionSound(rawValue: rawSound) {
            completionSound = sound
        }

        if let rawAppearance = defaults.string(forKey: DefaultsKey.appearance),
           let savedAppearance = AppAppearance(rawValue: rawAppearance) {
            appearance = savedAppearance
        }
        let warningGB = defaults.double(forKey: DefaultsKey.estimatedSizeWarningThresholdGB)
        if warningGB > 0 {
            estimatedSizeWarningThresholdGB = min(max(0.04, warningGB), 20.0)
        }
        let dangerGB = defaults.double(forKey: DefaultsKey.estimatedSizeDangerThresholdGB)
        if dangerGB > 0 {
            estimatedSizeDangerThresholdGB = min(max(0.05, dangerGB), 40.0)
        }
        if estimatedSizeDangerThresholdGB <= estimatedSizeWarningThresholdGB {
            estimatedSizeDangerThresholdGB = min(40.0, estimatedSizeWarningThresholdGB + 0.01)
        }

        let savedSilenceDuration = defaults.double(forKey: DefaultsKey.silenceMinDurationSeconds)
        if savedSilenceDuration > 0 {
            silenceMinDurationSeconds = min(5.0, max(0.5, savedSilenceDuration))
        }

        let savedProfanityWords = defaults.string(forKey: DefaultsKey.profanityWords) ?? defaultProfanityWordsStorageString
        profanityWordsText = savedProfanityWords

        if let rawFrameSaveMode = defaults.string(forKey: DefaultsKey.frameSaveLocationMode),
           let mode = FrameSaveLocationMode(rawValue: rawFrameSaveMode) {
            frameSaveLocationMode = mode
        }

        customFrameSaveDirectoryPath = defaults.string(forKey: DefaultsKey.customFrameSaveDirectoryPath) ?? ""

        if let rawURLPreset = defaults.string(forKey: DefaultsKey.urlDownloadPreset),
           let preset = URLDownloadPreset(rawValue: rawURLPreset) {
            urlDownloadPreset = preset
        }
        if let rawURLSaveMode = defaults.string(forKey: DefaultsKey.urlDownloadSaveLocationMode),
           let mode = URLDownloadSaveLocationMode(rawValue: rawURLSaveMode) {
            urlDownloadSaveLocationMode = mode
        }
        customURLDownloadDirectoryPath = defaults.string(forKey: DefaultsKey.customURLDownloadDirectoryPath) ?? ""
        if let rawURLAuthMode = defaults.string(forKey: DefaultsKey.urlDownloadAuthenticationMode),
           let mode = URLDownloadAuthenticationMode(rawValue: rawURLAuthMode) {
            urlDownloadAuthenticationMode = mode
        }
        if let rawURLBrowserSource = defaults.string(forKey: DefaultsKey.urlDownloadBrowserCookiesSource),
           let source = URLDownloadBrowserCookiesSource(rawValue: rawURLBrowserSource) {
            urlDownloadBrowserCookiesSource = source
        }

        if let rawCaptionStyle = defaults.string(forKey: DefaultsKey.burnInCaptionStyle),
           let style = BurnInCaptionStyle(rawValue: rawCaptionStyle) {
            clipAdvancedCaptionStyle = style
        }

        let savedBoostAmount = defaults.integer(forKey: DefaultsKey.advancedBoostAmount)
        if let boostAmount = AdvancedBoostAmount(rawValue: savedBoostAmount) {
            clipAdvancedBoostAmount = boostAmount
        }
    }

    var canAnalyze: Bool {
        sourceURL != nil && !isAnalyzing && !isExporting && !isGeneratingTranscript && (effectiveAnalyzeBlackFrames || effectiveAnalyzeAudioSilence || effectiveAnalyzeProfanity)
    }

    var canRequestAnalyze: Bool {
        sourceURL != nil && !isGeneratingTranscript && (effectiveAnalyzeBlackFrames || effectiveAnalyzeAudioSilence || effectiveAnalyzeProfanity)
    }

    var hasVideoTrack: Bool {
        guard let sourceInfo else { return false }
        if let bitrate = sourceInfo.videoBitrateBps, bitrate > 0 { return true }
        if let frameRate = sourceInfo.frameRate, frameRate > 0 { return true }
        if let resolution = sourceInfo.resolution, !resolution.isEmpty { return true }
        if let codec = sourceInfo.videoCodec, !codec.isEmpty { return true }
        return false
    }

    var effectiveAnalyzeBlackFrames: Bool {
        analyzeBlackFrames && hasVideoTrack
    }

    var effectiveAnalyzeAudioSilence: Bool {
        analyzeAudioSilence && hasAudioTrack
    }

    var effectiveAnalyzeProfanity: Bool {
        analyzeProfanity && hasAudioTrack
    }

    var whisperTranscriptionAvailable: Bool {
        cachedWhisperAvailable
    }

    var ffmpegAvailable: Bool {
        cachedFFmpegAvailable
    }

    var ffprobeAvailable: Bool {
        cachedFFprobeAvailable
    }

    var ytDLPToolAvailable: Bool {
        cachedYTDLPAvailable
    }

    var whisperCLIAvailable: Bool {
        cachedWhisperCLIAvailable
    }

    var whisperModelAvailable: Bool {
        cachedWhisperModelAvailable
    }

    var hasAudioTrack: Bool {
        guard let sourceInfo else { return false }
        if let bitrate = sourceInfo.audioBitrateBps, bitrate > 0 { return true }
        if let sampleRate = sourceInfo.sampleRateHz, sampleRate > 0 { return true }
        if let channels = sourceInfo.channels, channels > 0 { return true }
        if let codec = sourceInfo.audioCodec, !codec.isEmpty { return true }
        return false
    }

    var silenceMinDurationLabel: String {
        String(format: "%.1f", silenceMinDurationSeconds)
    }

    var selectedProfanityWords: Set<String> {
        profanityWordsFromString(profanityWordsText)
    }

    var selectedProfanityWordsCount: Int {
        selectedProfanityWords.count
    }

    var selectedProfanityWordsList: [String] {
        selectedProfanityWords.sorted()
    }

    var advancedClipFilenamePreview: String {
        let sampleSource = sourceURL?.deletingPathExtension().lastPathComponent ?? "source"
        let sampleStart = clipStartSeconds
        let sampleEnd = max(clipEndSeconds, clipStartSeconds + 1.0)
        let codecToken = selectedClipFormat == .webm ? "vp9" : (clipAdvancedVideoCodec == .hevc ? "hevc" : "h264")
        let resolutionToken: String
        if clipCompatibleMaxResolution == .original {
            resolutionToken = sourceInfo?.resolution ?? "original"
        } else {
            resolutionToken = clipCompatibleMaxResolution.rawValue
        }
        return ClipExportUtilities.advancedClipFilenameBase(
            sourceName: sampleSource,
            startSeconds: sampleStart,
            endSeconds: sampleEnd,
            codec: codecToken,
            resolution: resolutionToken,
            advancedFilenameTemplate: advancedClipFilenameTemplate
        ) + ".\(selectedClipFormat.fileExtension.lowercased())"
    }

    var canExport: Bool {
        sourceURL != nil && !isAnalyzing && !isExporting && !isGeneratingTranscript
    }

    var ytDLPAvailable: Bool {
        cachedYTDLPAvailable
    }

    var analyzeProgress: Double {
        get { activityPresentation.analyzeProgress }
        set {
            activityPresentation.analyzeProgress = newValue
            updateDockProgressIndicator()
        }
    }

    var analyzeStatusText: String {
        get { activityPresentation.analyzeStatusText }
        set { activityPresentation.analyzeStatusText = newValue }
    }

    var exportProgress: Double {
        get { activityPresentation.exportProgress }
        set {
            activityPresentation.exportProgress = newValue
            updateDockProgressIndicator()
        }
    }

    var exportStatusText: String {
        get { activityPresentation.exportStatusText }
        set { activityPresentation.exportStatusText = newValue }
    }

    var uiMessage: String {
        get { activityPresentation.uiMessage }
        set { activityPresentation.uiMessage = newValue }
    }

    var lastActivityState: ActivityState {
        get { activityPresentation.lastActivityState }
        set { activityPresentation.lastActivityState = newValue }
    }

    var showActivityConsole: Bool {
        get { activityPresentation.showActivityConsole }
        set { activityPresentation.showActivityConsole = newValue }
    }

    var activityConsoleText: String {
        get { activityPresentation.activityConsoleText }
        set { activityPresentation.activityConsoleText = newValue }
    }

    var urlDownloadSetupComplete: Bool {
        managedPythonVersionText != "Unavailable" && ytDLPToolAvailable
    }

    var canRequestURLDownload: Bool {
        !isAnalyzing && !isExporting && !isGeneratingTranscript
    }

    var canRequestAudioExport: Bool {
        sourceURL != nil && !isGeneratingTranscript
    }

    var canGenerateTranscript: Bool {
        sourceURL != nil
            && hasAudioTrack
            && whisperTranscriptionAvailable
            && !isAnalyzing
            && !isExporting
            && !isGeneratingTranscript
            && !hasCachedTranscript
    }

    var sourceDurationSeconds: Double {
        max(0, sourceInfo?.durationSeconds ?? analysis?.mediaDuration ?? 0)
    }

    var canExportClip: Bool {
        sourceURL != nil &&
        sourceDurationSeconds > 0 &&
        clipEndSeconds > clipStartSeconds &&
        !isAnalyzing &&
        !isExporting
    }

    var canQueueClipExport: Bool {
        sourceURL != nil &&
        sourceDurationSeconds > 0 &&
        clipEndSeconds > clipStartSeconds &&
        !isGeneratingTranscript
    }

    var canRequestClipExport: Bool {
        sourceURL != nil &&
        sourceDurationSeconds > 0 &&
        clipEndSeconds > clipStartSeconds &&
        !isGeneratingTranscript
    }

    var clipDurationSeconds: Double {
        max(0, clipEndSeconds - clipStartSeconds)
    }

    var estimatedAudioExportSizeBytes: Int64? {
        guard selectedAudioFormat == .mp3 else { return nil }
        return estimateFileSizeBytes(
            durationSeconds: sourceDurationSeconds,
            totalBitrateKbps: Double(exportAudioBitrateKbps)
        )
    }

    var estimatedClipAudioOnlySizeBytes: Int64? {
        guard clipAudioOnlyFormat != .wav else { return nil }
        return estimateFileSizeBytes(
            durationSeconds: clipDurationSeconds,
            totalBitrateKbps: Double(clipAudioBitrateKbps)
        )
    }

    var estimatedClipAdvancedSizeBytes: Int64? {
        guard clipEncodingMode == .compressed else { return nil }
        let hasAudioTrack = (sourceInfo?.channels ?? 0) > 0 || (sourceInfo?.audioBitrateBps ?? 0) > 0
        let totalBitrateKbps = (clipVideoBitrateMbps * 1000.0) + (hasAudioTrack ? Double(clipAudioBitrateKbps) : 0)
        return estimateFileSizeBytes(
            durationSeconds: clipDurationSeconds,
            totalBitrateKbps: totalBitrateKbps
        )
    }

    var isActivityRunning: Bool {
        isAnalyzing || isExporting
    }

    var hasQueuedJobs: Bool {
        !queuedJobs.isEmpty
    }

    func clearActivityConsole() {
        activityConsoleFlushTask?.cancel()
        activityConsoleFlushTask = nil
        pendingActivityConsoleText = ""
        activityConsoleText = ""
    }

    func copyActivityConsole() {
        flushPendingActivityConsole()
        guard !activityConsoleText.isEmpty else { return }
        copyToClipboard(activityConsoleText)
    }

    func appendActivityConsoleChunk(_ chunk: String) {
        guard showActivityConsole else { return }
        let cleanedChunk = chunk.trimmingCharacters(in: .newlines)
        guard !cleanedChunk.isEmpty else { return }

        if pendingActivityConsoleText.isEmpty {
            pendingActivityConsoleText = cleanedChunk
        } else {
            pendingActivityConsoleText += "\n" + cleanedChunk
        }

        scheduleActivityConsoleFlush()
    }

    func appendActivityConsole(_ line: String, source: String? = nil) {
        guard showActivityConsole else { return }

        let cleaned = line.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .newlines)
        guard !cleaned.isEmpty else { return }

        let renderedLine: String
        if let source, !source.isEmpty {
            renderedLine = "[\(source)] \(cleaned)"
        } else {
            renderedLine = cleaned
        }

        appendActivityConsoleChunk(renderedLine)
    }

    private func scheduleActivityConsoleFlush() {
        guard activityConsoleFlushTask == nil else { return }
        activityConsoleFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let flushDelay = self.activityConsoleFlushIntervalNanos
            try? await Task.sleep(nanoseconds: flushDelay)
            self.activityConsoleFlushTask = nil
            self.flushPendingActivityConsole()
        }
    }

    private func flushPendingActivityConsole() {
        guard !pendingActivityConsoleText.isEmpty else { return }
        let pendingChunk = pendingActivityConsoleText
        pendingActivityConsoleText = ""

        if activityConsoleText.isEmpty {
            activityConsoleText = pendingChunk
        } else {
            activityConsoleText += "\n" + pendingChunk
        }

        if activityConsoleText.count > maxActivityConsoleCharacters {
            let trimCount = activityConsoleText.count - activityConsoleTrimCharacters
            if trimCount > 0 {
                let start = activityConsoleText.index(activityConsoleText.startIndex, offsetBy: trimCount)
                activityConsoleText = String(activityConsoleText[start...])
            }
        }
    }

    func scheduleAnalyzeFeedbackUpdate(progress: Double? = nil, fileName: String, immediate: Bool = false) {
        activeAnalyzeFeedbackFileName = fileName
        if let progress {
            pendingAnalyzeFeedbackProgress = min(1, max(0, progress))
        }

        if immediate {
            flushAnalyzeFeedbackUpdate()
            return
        }

        guard analyzeFeedbackFlushTask == nil else { return }
        analyzeFeedbackFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let flushDelay = self.analyzeFeedbackFlushIntervalNanos
            try? await Task.sleep(nanoseconds: flushDelay)
            self.analyzeFeedbackFlushTask = nil
            self.flushAnalyzeFeedbackUpdate()
        }
    }

    func flushAnalyzeFeedbackUpdate() {
        guard activeAnalyzeFeedbackFileName != nil else { return }
        if PlayheadDiagnostics.shared.isScenarioActive {
            PlayheadDiagnostics.shared.noteModelWrite("analyze_feedback_flush")
        }

        let progress = pendingAnalyzeFeedbackProgress ?? analyzeProgress
        let clamped = min(1, max(0, progress))
        pendingAnalyzeFeedbackProgress = nil

        if analyzeProgress != clamped {
            analyzeProgress = clamped
        }

        let statusText = renderedAnalyzeStatusText(progress: clamped)
        if analyzeStatusText != statusText {
            analyzeStatusText = statusText
        }

        if var current = analysis,
           case .running = current.status,
           abs(current.progress - clamped) > 0.0001 {
            current.progress = clamped
            analysis = current
        }
    }

    func cancelAnalyzeFeedbackUpdates() {
        analyzeFeedbackFlushTask?.cancel()
        analyzeFeedbackFlushTask = nil
        pendingAnalyzeFeedbackProgress = nil
        activeAnalyzeFeedbackFileName = nil
    }

    func renderedAnalyzeStatusText(progress: Double) -> String {
        let percent = Int((min(1, max(0, progress)) * 100).rounded())
        return "\(analyzePhaseText)… \(percent)%"
    }

    func stopCurrentActivity() {
        if isGeneratingTranscript {
            stopAnalysis()
            return
        }
        if isAnalyzing {
            stopAnalysis()
            return
        }
        if isExporting {
            stopExport()
        }
    }

    func waveformSamplesFromCache(for url: URL, sampleCount: Int) -> [Double]? {
        waveformCache[waveformCacheKey(for: url, sampleCount: sampleCount)]
    }

    func cacheWaveformSamples(_ samples: [Double], for url: URL, sampleCount: Int) {
        let key = waveformCacheKey(for: url, sampleCount: sampleCount)
        waveformCache[key] = samples
        waveformCacheOrder.removeAll { $0 == key }
        waveformCacheOrder.append(key)

        if waveformCacheOrder.count > maxWaveformCacheEntries, let oldest = waveformCacheOrder.first {
            waveformCache.removeValue(forKey: oldest)
            waveformCacheOrder.removeFirst()
        }
    }

    private func waveformCacheKey(for url: URL, sampleCount: Int) -> String {
        "\(url.path)|\(sampleCount)"
    }

    func timelineThumbnailStripImageFromCache(forKey key: String) -> CGImage? {
        guard let image = timelineThumbnailStripCache[key] else { return nil }
        timelineThumbnailStripCacheOrder.removeAll { $0 == key }
        timelineThumbnailStripCacheOrder.append(key)
        return image
    }

    func cacheTimelineThumbnailStripImage(_ image: CGImage, forKey key: String) {
        timelineThumbnailStripCache[key] = image
        timelineThumbnailStripCacheOrder.removeAll { $0 == key }
        timelineThumbnailStripCacheOrder.append(key)

        if timelineThumbnailStripCacheOrder.count > maxTimelineThumbnailStripCacheEntries,
           let oldest = timelineThumbnailStripCacheOrder.first {
            timelineThumbnailStripCache.removeValue(forKey: oldest)
            timelineThumbnailStripCacheOrder.removeFirst()
        }
    }

    func notifyCompletion(_ title: String, message: String) {
        let center = UNUserNotificationCenter.current()

        let enqueue = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request)
        }

        if notificationAuthRequested {
            enqueue()
            return
        }

        notificationAuthRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                enqueue()
            }
        }
    }
}
