import SwiftUI
import AppKit
import AVFoundation
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
    }

    @Published var selectedTool: WorkspaceTool = .clip
    @Published var sourceURL: URL?
    @Published var sourceSessionID = UUID()
    @Published var analysis: FileAnalysis?
    @Published var sourceInfo: SourceMediaInfo?
    @Published var transcriptSegments: [TranscriptSegment] = []
    @Published var transcriptStatusText: String = "No transcript generated yet."
    @Published var hasCachedTranscript = false
    @Published var isGeneratingTranscript = false

    @Published var isAnalyzing = false {
        didSet {
            updateDockProgressIndicator()
            if oldValue && !isAnalyzing {
                startNextQueuedJobIfPossible()
            }
        }
    }
    @Published var analyzeProgress = 0.0 {
        didSet { updateDockProgressIndicator() }
    }
    @Published var analyzeStatusText = ""
    @Published var analyzePhaseText = "Preparing analysis"
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
    @Published var exportProgress = 0.0 {
        didSet { updateDockProgressIndicator() }
    }
    @Published var exportStatusText = "No export yet"
    @Published var outputURL: URL?
    @Published private(set) var queuedJobs: [QueuedClipExport] = []
    @Published private(set) var activeQueuedJobID: UUID?
    @Published private(set) var captureTimelineMarkers: [CaptureTimelineMarker] = []
    @Published var highlightedCaptureTimelineMarkerID: UUID?
    @Published var highlightedClipBoundary: ClipBoundaryHighlight?
    @Published var captureFrameFlashToken: Int = 0
    @Published var quickExportFlashToken: Int = 0

    @Published var clipStartSeconds: Double = 0
    @Published var clipEndSeconds: Double = 0
    @Published var clipPlayheadSeconds: Double = 0
    @Published var clipStartText = "00:00:00.000"
    @Published var clipEndText = "00:00:00.000"
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

    @Published var uiMessage = "Ready"
    @Published var lastActivityState: ActivityState = .idle
    @Published var showActivityConsole = false
    @Published var activityConsoleText = ""
    @Published var isURLImportSheetPresented = false

    private var analyzeTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var captureMarkerHighlightClearTask: Task<Void, Never>?
    private var clipBoundaryHighlightClearTask: Task<Void, Never>?
    private let cancelFlag = CancellationFlag()
    private var activeExportSession: AVAssetExportSession?
    private var activeProcess: Process?
    private var activeClipExportRunToken: UUID?
    private var willTerminateObserver: NSObjectProtocol?
    private var exportCancellationRequested = false
    private var notificationAuthRequested = false
    private var originalModeDefaultBitrateMbps: Double = 4.0
    private struct QueuedClipExportConfig {
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
    private struct QueuedAudioExportConfig {
        let selectedAudioFormat: AudioFormat
        let exportAudioBitrateKbps: Int
        let destinationURL: URL?
    }
    private struct QueuedAnalysisConfig {
        let analyzeBlackFrames: Bool
        let analyzeAudioSilence: Bool
        let analyzeProfanity: Bool
        let silenceMinDurationSeconds: Double
        let profanityWordsText: String
    }
    private var queuedJobKinds: [UUID: QueuedJobKind] = [:]
    private var queuedClipExportConfigs: [UUID: QueuedClipExportConfig] = [:]
    private var queuedAudioExportConfigs: [UUID: QueuedAudioExportConfig] = [:]
    private var queuedAnalysisConfigs: [UUID: QueuedAnalysisConfig] = [:]
    private var waveformCache: [String: [Double]] = [:]
    private var waveformCacheOrder: [String] = []
    private let maxWaveformCacheEntries = 6
    private let maxActivityConsoleCharacters = 200_000
    private let activityConsoleTrimCharacters = 150_000
    private var cachedFFmpegAvailable = false
    private var cachedFFprobeAvailable = false
    private var cachedYTDLPAvailable = false
    private var cachedWhisperCLIAvailable = false
    private var cachedWhisperModelAvailable = false
    private var cachedWhisperAvailable = false

    init() {
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopCurrentActivity()
        }

        loadPreferences()
        refreshExternalToolAvailabilityCache()
        if let firstArg = CommandLine.arguments.dropFirst().first {
            let url = URL(fileURLWithPath: firstArg)
            if FileManager.default.fileExists(atPath: url.path) {
                setSource(url)
            }
        }
    }

    deinit {
        if let willTerminateObserver {
            NotificationCenter.default.removeObserver(willTerminateObserver)
        }
        captureMarkerHighlightClearTask?.cancel()
        clipBoundaryHighlightClearTask?.cancel()
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
        return advancedClipFilenameBase(
            sourceName: sampleSource,
            startSeconds: sampleStart,
            endSeconds: sampleEnd,
            codec: codecToken,
            resolution: resolutionToken
        ) + ".\(selectedClipFormat.fileExtension.lowercased())"
    }

    var canExport: Bool {
        sourceURL != nil && !isAnalyzing && !isExporting && !isGeneratingTranscript
    }

    var ytDLPAvailable: Bool {
        cachedYTDLPAvailable
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

    private func refreshExternalToolAvailabilityCache() {
        cachedFFmpegAvailable = (findFFmpegExecutable() != nil)
        cachedFFprobeAvailable = (findFFprobeExecutable() != nil)
        if let ytDLPURL = findYTDLPExecutable() {
            cachedYTDLPAvailable = isMachOExecutable(at: ytDLPURL) || (findPython3Executable() != nil)
        } else {
            cachedYTDLPAvailable = false
        }
        cachedWhisperCLIAvailable = (findWhisperExecutable() != nil)
        cachedWhisperModelAvailable = (findWhisperModel() != nil)
        cachedWhisperAvailable = (cachedWhisperCLIAvailable && cachedWhisperModelAvailable)
    }

    func recheckSetupChecks() {
        refreshExternalToolAvailabilityCache()
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

    var activityProgress: Double? {
        if isAnalyzing { return analyzeProgress }
        if isExporting { return exportProgress }
        return nil
    }

    var activityText: String {
        if isAnalyzing { return analyzeStatusText }
        if isExporting { return exportStatusText }
        return uiMessage
    }

    var isActivityRunning: Bool {
        isAnalyzing || isExporting
    }

    var lastResultIconName: String {
        switch lastActivityState {
        case .idle:
            return "circle.dashed"
        case .running:
            return "hourglass"
        case .success:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .cancelled:
            return "stop.circle.fill"
        }
    }

    var lastResultLabel: String {
        switch lastActivityState {
        case .idle:
            return "Idle"
        case .running:
            return "Running"
        case .success:
            return "Success"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    var hasQueuedJobs: Bool {
        !queuedJobs.isEmpty
    }

    private func beginDirectJobTracking(fileName: String, summary: String, subtitle: String? = nil) -> UUID {
        let id = UUID()
        let item = QueuedClipExport(
            id: id,
            createdAt: Date(),
            fileName: fileName,
            summary: summary,
            subtitle: subtitle,
            status: .running,
            message: nil
        )
        queuedJobs.append(item)
        activeQueuedJobID = id
        return id
    }

    private func clipJobTitle(skipSaveDialog: Bool, mode: ClipEncodingMode) -> String {
        let prefix = skipSaveDialog ? "Quick " : ""
        switch mode {
        case .fast:
            return "\(prefix)Clip Export - Fast Copy"
        case .compressed:
            return "\(prefix)Clip Export - Advanced Encode"
        case .audioOnly:
            return "\(prefix)Clip Export - Audio Only"
        }
    }

    private func clipJobSubtitle(
        mode: ClipEncodingMode,
        format: String,
        startSeconds: Double,
        endSeconds: Double
    ) -> String {
        "\(mode.rawValue) • \(format) • \(formatSeconds(startSeconds)) → \(formatSeconds(endSeconds))"
    }

    private func audioExportJobTitle(format: AudioFormat) -> String {
        "Audio Export - \(format.rawValue)"
    }

    private func audioExportJobSubtitle(bitrateKbps: Int) -> String {
        "\(bitrateKbps) kbps"
    }

    private func analysisJobSubtitle(black: Bool, silence: Bool, profanity: Bool) -> String {
        var detectors: [String] = []
        if black { detectors.append("Black Frames") }
        if silence { detectors.append("Silence") }
        if profanity { detectors.append("Profanity") }
        if detectors.isEmpty { return "No detectors selected" }
        return detectors.joined(separator: " + ")
    }

    private func analysisJobTitle(black: Bool, silence: Bool, profanity: Bool) -> String {
        let enabledCount = [black, silence, profanity].filter { $0 }.count
        if enabledCount <= 1 {
            if black { return "Analyze - Black Frames" }
            if silence { return "Analyze - Silence Gaps" }
            if profanity { return "Analyze - Profanity" }
            return "Analyze Media"
        }
        return "Analyze Media"
    }

    private func defaultAudioExportFileName(for sourceURL: URL) -> String {
        if selectedAudioFormat == .mp3 {
            return sourceURL.deletingPathExtension().lastPathComponent + ".mp3"
        }
        return sourceURL.deletingPathExtension().lastPathComponent + ".m4a"
    }

    private func promptAudioExportDestination(for sourceURL: URL) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultAudioExportFileName(for: sourceURL)
        panel.allowedContentTypes = selectedAudioFormat == .mp3 ? [.mp3] : [.mpeg4Audio]
        panel.canCreateDirectories = true
        panel.title = "Export Audio"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func defaultClipExportFileName(for sourceURL: URL) -> String {
        let outputExtension = clipEncodingMode == .audioOnly ? clipAudioOnlyFormat.fileExtension : selectedClipFormat.fileExtension
        let defaultBaseName: String
        if clipEncodingMode == .compressed {
            let codecToken = selectedClipFormat == .webm ? "vp9" : (clipAdvancedVideoCodec == .hevc ? "hevc" : "h264")
            let resolutionToken: String
            if clipCompatibleMaxResolution == .original {
                resolutionToken = sourceInfo?.resolution ?? "original"
            } else {
                resolutionToken = clipCompatibleMaxResolution.rawValue
            }
            defaultBaseName = advancedClipFilenameBase(
                sourceName: sourceURL.deletingPathExtension().lastPathComponent,
                startSeconds: clipStartSeconds,
                endSeconds: clipEndSeconds,
                codec: codecToken,
                resolution: resolutionToken
            )
        } else {
            defaultBaseName = sourceURL.deletingPathExtension().lastPathComponent +
                "_clip_" + formatSeconds(clipStartSeconds).replacingOccurrences(of: ":", with: "-") +
                "_to_" + formatSeconds(clipEndSeconds).replacingOccurrences(of: ":", with: "-")
        }

        return URL(fileURLWithPath: defaultBaseName).deletingPathExtension().lastPathComponent + "." + outputExtension
    }

    private func promptClipExportDestination(for sourceURL: URL, defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [clipEncodingMode == .audioOnly ? clipAudioOnlyFormat.contentType : selectedClipFormat.contentType]
        panel.canCreateDirectories = true
        panel.title = "Export Clip"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func enqueueCurrentClipExport(skipSaveDialog: Bool = false) {
        guard canQueueClipExport, let sourceURL else { return }
        let destinationURL: URL?
        if skipSaveDialog {
            destinationURL = nil
        } else {
            let defaultName = defaultClipExportFileName(for: sourceURL)
            guard let chosenURL = promptClipExportDestination(for: sourceURL, defaultName: defaultName) else {
                uiMessage = "Save cancelled."
                return
            }
            destinationURL = chosenURL
        }
        let config = queuedClipExportConfigSnapshot(destinationURL: destinationURL)
        let formatLabel = config.clipEncodingMode == .audioOnly ? config.clipAudioOnlyFormat.rawValue : config.selectedClipFormat.rawValue
        let summary = clipJobTitle(skipSaveDialog: skipSaveDialog, mode: config.clipEncodingMode)
        let subtitle = clipJobSubtitle(
            mode: config.clipEncodingMode,
            format: formatLabel,
            startSeconds: config.clipStartSeconds,
            endSeconds: config.clipEndSeconds
        )
        let item = QueuedClipExport(
            id: UUID(),
            createdAt: Date(),
            fileName: sourceURL.lastPathComponent,
            summary: summary,
            subtitle: subtitle,
            status: .queued,
            message: nil
        )
        queuedJobKinds[item.id] = .clip(skipSaveDialog: skipSaveDialog)
        queuedClipExportConfigs[item.id] = config
        queuedJobs.append(item)
        uiMessage = "Queued job (\(queuedJobs.count) pending)"
        startNextQueuedJobIfPossible()
    }

    func enqueueCurrentAudioExport() {
        guard canRequestAudioExport, let sourceURL else { return }
        guard let destinationURL = promptAudioExportDestination(for: sourceURL) else {
            uiMessage = "Save cancelled."
            return
        }
        let item = QueuedClipExport(
            id: UUID(),
            createdAt: Date(),
            fileName: sourceURL.lastPathComponent,
            summary: audioExportJobTitle(format: selectedAudioFormat),
            subtitle: audioExportJobSubtitle(bitrateKbps: exportAudioBitrateKbps),
            status: .queued,
            message: nil
        )
        queuedJobKinds[item.id] = .audioExport
        queuedAudioExportConfigs[item.id] = QueuedAudioExportConfig(
            selectedAudioFormat: selectedAudioFormat,
            exportAudioBitrateKbps: exportAudioBitrateKbps,
            destinationURL: destinationURL
        )
        queuedJobs.append(item)
        uiMessage = "Queued job (\(queuedJobs.count) pending)"
        startNextQueuedJobIfPossible()
    }

    func enqueueCurrentAnalysis() {
        guard canRequestAnalyze, let sourceURL else { return }
        let item = QueuedClipExport(
            id: UUID(),
            createdAt: Date(),
            fileName: sourceURL.lastPathComponent,
            summary: analysisJobTitle(
                black: analyzeBlackFrames,
                silence: analyzeAudioSilence,
                profanity: analyzeProfanity
            ),
            subtitle: analysisJobSubtitle(
                black: analyzeBlackFrames,
                silence: analyzeAudioSilence,
                profanity: analyzeProfanity
            ),
            status: .queued,
            message: nil
        )
        queuedJobKinds[item.id] = .analysis
        queuedAnalysisConfigs[item.id] = QueuedAnalysisConfig(
            analyzeBlackFrames: analyzeBlackFrames,
            analyzeAudioSilence: analyzeAudioSilence,
            analyzeProfanity: analyzeProfanity,
            silenceMinDurationSeconds: silenceMinDurationSeconds,
            profanityWordsText: profanityWordsText
        )
        queuedJobs.append(item)
        uiMessage = "Queued job (\(queuedJobs.count) pending)"
        startNextQueuedJobIfPossible()
    }

    func removeQueuedJob(_ id: UUID) {
        if activeQueuedJobID == id {
            stopCurrentActivity()
            return
        }
        queuedJobs.removeAll { $0.id == id }
        queuedJobKinds[id] = nil
        queuedClipExportConfigs[id] = nil
        queuedAudioExportConfigs[id] = nil
        queuedAnalysisConfigs[id] = nil
    }

    func retryQueuedJob(_ id: UUID) {
        guard let index = queuedJobs.firstIndex(where: { $0.id == id }) else { return }
        queuedJobs[index].status = .queued
        queuedJobs[index].message = nil
        queuedJobs[index].outputURL = nil
        startNextQueuedJobIfPossible()
    }

    func clearCompletedQueuedJobs() {
        let removableIDs = Set(
            queuedJobs
                .filter { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
                .map(\.id)
        )
        queuedJobs.removeAll { removableIDs.contains($0.id) }
        for id in removableIDs {
            queuedJobKinds[id] = nil
            queuedClipExportConfigs[id] = nil
            queuedAudioExportConfigs[id] = nil
            queuedAnalysisConfigs[id] = nil
        }
    }

    private func queuedClipExportConfigSnapshot(destinationURL: URL? = nil) -> QueuedClipExportConfig {
        QueuedClipExportConfig(
            clipStartSeconds: clipStartSeconds,
            clipEndSeconds: clipEndSeconds,
            clipEncodingMode: clipEncodingMode,
            selectedClipFormat: selectedClipFormat,
            clipAudioOnlyFormat: clipAudioOnlyFormat,
            clipAdvancedVideoCodec: clipAdvancedVideoCodec,
            clipCompatibleSpeedPreset: clipCompatibleSpeedPreset,
            clipCompatibleMaxResolution: clipCompatibleMaxResolution,
            clipVideoBitrateMbps: clipVideoBitrateMbps,
            clipAudioBitrateKbps: clipAudioBitrateKbps,
            clipAdvancedBoostAudio: clipAdvancedBoostAudio,
            clipAdvancedBoostAmount: clipAdvancedBoostAmount,
            clipAdvancedAddFadeInOut: clipAdvancedAddFadeInOut,
            clipAdvancedBurnInCaptions: clipAdvancedBurnInCaptions,
            clipAdvancedCaptionStyle: clipAdvancedCaptionStyle,
            clipAudioOnlyBoostAudio: clipAudioOnlyBoostAudio,
            clipAudioOnlyAddFadeInOut: clipAudioOnlyAddFadeInOut,
            destinationURL: destinationURL
        )
    }

    private func applyQueuedClipExportConfig(_ config: QueuedClipExportConfig) {
        clipStartSeconds = config.clipStartSeconds
        clipEndSeconds = config.clipEndSeconds
        clipEncodingMode = config.clipEncodingMode
        selectedClipFormat = config.selectedClipFormat
        clipAudioOnlyFormat = config.clipAudioOnlyFormat
        clipAdvancedVideoCodec = config.clipAdvancedVideoCodec
        clipCompatibleSpeedPreset = config.clipCompatibleSpeedPreset
        clipCompatibleMaxResolution = config.clipCompatibleMaxResolution
        clipVideoBitrateMbps = config.clipVideoBitrateMbps
        clipAudioBitrateKbps = config.clipAudioBitrateKbps
        clipAdvancedBoostAudio = config.clipAdvancedBoostAudio
        clipAdvancedBoostAmount = config.clipAdvancedBoostAmount
        clipAdvancedAddFadeInOut = config.clipAdvancedAddFadeInOut
        clipAdvancedBurnInCaptions = config.clipAdvancedBurnInCaptions
        clipAdvancedCaptionStyle = config.clipAdvancedCaptionStyle
        clipAudioOnlyBoostAudio = config.clipAudioOnlyBoostAudio
        clipAudioOnlyAddFadeInOut = config.clipAudioOnlyAddFadeInOut
        syncClipTextFields()
    }

    private func clearQueuedJobs() {
        queuedJobs.removeAll()
        queuedJobKinds.removeAll()
        queuedClipExportConfigs.removeAll()
        queuedAudioExportConfigs.removeAll()
        queuedAnalysisConfigs.removeAll()
        activeQueuedJobID = nil
    }

    private func startNextQueuedJobIfPossible() {
        guard !isAnalyzing, !isExporting, !isGeneratingTranscript, activeQueuedJobID == nil else { return }
        guard let next = queuedJobs.first(where: { $0.status == .queued }),
              let kind = queuedJobKinds[next.id] else { return }
        if let index = queuedJobs.firstIndex(where: { $0.id == next.id }) {
            queuedJobs[index].status = .running
            queuedJobs[index].message = nil
        }
        activeQueuedJobID = next.id
        switch kind {
        case .clip(let skipSaveDialog):
            guard let config = queuedClipExportConfigs[next.id] else {
                completeQueuedJobIfNeeded(next.id, status: .failed, message: "Missing clip export config.")
                return
            }
            applyQueuedClipExportConfig(config)
            startClipExport(skipSaveDialog: skipSaveDialog, queueJobID: next.id, preselectedDestination: config.destinationURL)
        case .audioExport:
            guard let config = queuedAudioExportConfigs[next.id] else {
                completeQueuedJobIfNeeded(next.id, status: .failed, message: "Missing audio export config.")
                return
            }
            selectedAudioFormat = config.selectedAudioFormat
            exportAudioBitrateKbps = config.exportAudioBitrateKbps
            startExport(queueJobID: next.id, preselectedDestination: config.destinationURL)
        case .analysis:
            guard let config = queuedAnalysisConfigs[next.id] else {
                completeQueuedJobIfNeeded(next.id, status: .failed, message: "Missing analysis config.")
                return
            }
            analyzeBlackFrames = config.analyzeBlackFrames
            analyzeAudioSilence = config.analyzeAudioSilence
            analyzeProfanity = config.analyzeProfanity
            silenceMinDurationSeconds = config.silenceMinDurationSeconds
            profanityWordsText = config.profanityWordsText
            startAnalysis(queueJobID: next.id)
        }
    }

    private func completeQueuedJobIfNeeded(_ queueJobID: UUID?, status: ClipExportQueueStatus, message: String? = nil, outputURL: URL? = nil) {
        let resolvedJobID = queueJobID ?? activeQueuedJobID
        guard let resolvedJobID else { return }
        if let index = queuedJobs.firstIndex(where: { $0.id == resolvedJobID }) {
            queuedJobs[index].status = status
            queuedJobs[index].message = message
            queuedJobs[index].outputURL = outputURL
        }
        activeQueuedJobID = nil
        DispatchQueue.main.async { [weak self] in
            self?.startNextQueuedJobIfPossible()
        }
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a media file"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.urls.first {
            setSource(url)
        }
    }

    func presentURLImportSheet() {
        guard canRequestURLDownload else {
            uiMessage = "Finish current task before downloading."
            return
        }
        guard ytDLPAvailable else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "yt-dlp Not Available"
            alert.informativeText = "Install yt-dlp, then try again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            uiMessage = "yt-dlp is required to import from URL."
            return
        }
        isURLImportSheetPresented = true
    }

    // Backwards compatibility for existing call sites.
    func importSourceFromURL() {
        presentURLImportSheet()
    }

    func startURLImport(
        urlText: String,
        preset: URLDownloadPreset,
        saveMode: URLDownloadSaveLocationMode,
        customFolderPath: String?
    ) {
        guard canRequestURLDownload else {
            uiMessage = "Finish current task before downloading."
            return
        }
        guard let ytDLPLaunch = resolveYTDLPLaunch() else {
            uiMessage = "yt-dlp is required to import from URL."
            return
        }
        guard let normalized = normalizedDownloadURL(from: urlText) else {
            return
        }

        urlDownloadPreset = preset
        urlDownloadSaveLocationMode = saveMode
        if let customFolderPath {
            customURLDownloadDirectoryPath = customFolderPath
        }

        if preset.requiresTranscodeWarning && !confirmTranscodeDownloadWarning() {
            uiMessage = "Download cancelled."
            return
        }

        guard let destinationURL = resolveURLDownloadDestination(
            for: preset,
            sourceURL: normalized,
            saveModeOverride: saveMode,
            customFolderPathOverride: customFolderPath
        ) else {
            uiMessage = "Unable to resolve download destination."
            return
        }

        isExporting = true
        lastActivityState = .running
        exportCancellationRequested = false
        exportProgress = 0
        clearActivityConsole()
        appendActivityConsole("URL download started", source: "yt-dlp")
        exportStatusText = "Preparing download…"
        uiMessage = "Downloading media from URL…"

        exportTask = Task { [weak self] in
            guard let self else { return }
            let ffmpegURL = self.findFFmpegExecutable()
            let ffmpegDirectory = ffmpegURL?.deletingLastPathComponent().path
            let shouldSplitTranscodeStages = preset == .bestAnyToMP4
            var temporaryStageDirectory: URL?
            defer {
                if let temporaryStageDirectory {
                    try? FileManager.default.removeItem(at: temporaryStageDirectory)
                }
            }

            let (downloadedPath, errorText): (String?, String?)
            if shouldSplitTranscodeStages {
                let tempRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("inout-url-download-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                temporaryStageDirectory = tempRoot

                let downloadTemplateURL = tempRoot.appendingPathComponent("downloaded.%(ext)s")
                let stagedArgs = [
                    "--no-playlist",
                    "--newline",
                    "--progress",
                    "--progress-template", "download:%(progress._percent_str)s",
                    "--print", "after_move:%(filepath)s",
                    "-o", downloadTemplateURL.path,
                    normalized.absoluteString
                ] + self.ytDLPFormatArguments(for: preset) + (ffmpegDirectory.map { ["--ffmpeg-location", $0] } ?? [])

                let staged = await self.runYTDLPProcessWithProgress(
                    executableURL: ytDLPLaunch.executableURL,
                    preArguments: ytDLPLaunch.preArguments,
                    arguments: stagedArgs,
                    statusPrefix: "Downloading source",
                    progressRange: 0.0...0.6
                )
                downloadedPath = staged.downloadedPath
                errorText = staged.error
            } else {
                let args = [
                    "--no-playlist",
                    "--newline",
                    "--progress",
                    "--progress-template", "download:%(progress._percent_str)s",
                    "--print", "after_move:%(filepath)s",
                    "-o", destinationURL.path,
                    normalized.absoluteString
                ] + self.ytDLPFormatArguments(for: preset) + (ffmpegDirectory.map { ["--ffmpeg-location", $0] } ?? [])

                let direct = await self.runYTDLPProcessWithProgress(
                    executableURL: ytDLPLaunch.executableURL,
                    preArguments: ytDLPLaunch.preArguments,
                    arguments: args,
                    statusPrefix: "Downloading media",
                    progressRange: 0.0...1.0
                )
                downloadedPath = direct.downloadedPath
                errorText = direct.error
            }

            await MainActor.run {
                if self.exportCancellationRequested {
                    self.exportTask = nil
                    self.activeProcess = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    self.exportStatusText = "Download cancelled"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .cancelled
                    return
                }
            }

            if let errorText {
                await MainActor.run {
                    self.exportTask = nil
                    self.activeProcess = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    self.exportStatusText = "Download failed: \(errorText)"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                }
                return
            }

            guard let downloadedPath, FileManager.default.fileExists(atPath: downloadedPath) else {
                await MainActor.run {
                    self.exportTask = nil
                    self.activeProcess = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    self.exportStatusText = "Download failed: yt-dlp did not return an output file path."
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                }
                return
            }

            var finalURL = URL(fileURLWithPath: downloadedPath)

            if shouldSplitTranscodeStages {
                guard let ffmpegURL else {
                    await MainActor.run {
                        self.exportTask = nil
                        self.activeProcess = nil
                        self.isExporting = false
                        self.exportProgress = 0
                        self.exportStatusText = "Download failed: ffmpeg is required for this mode."
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                    }
                    return
                }

                let stagedAsset = AVURLAsset(url: finalURL)
                var stagedDurationSeconds: Double = 0
                if #available(macOS 13.0, *) {
                    if let loadedDuration = try? await stagedAsset.load(.duration) {
                        let seconds = CMTimeGetSeconds(loadedDuration)
                        if seconds.isFinite && seconds > 0.001 {
                            stagedDurationSeconds = seconds
                        }
                    }
                }
                if stagedDurationSeconds <= 0.001 {
                    let fallbackDirect = CMTimeGetSeconds(stagedAsset.duration)
                    if fallbackDirect.isFinite && fallbackDirect > 0.001 {
                        stagedDurationSeconds = fallbackDirect
                    }
                }
                if stagedDurationSeconds <= 0.001 {
                    let probed = loadSourceMediaInfo(for: finalURL).durationSeconds ?? 0
                    if probed.isFinite && probed > 0.001 {
                        stagedDurationSeconds = probed
                    }
                }
                let stagedInfo = loadSourceMediaInfo(for: finalURL)
                if stagedDurationSeconds <= 0.001 {
                    // Last-resort guard: avoid tiny denominator causing immediate 100%.
                    stagedDurationSeconds = 600.0
                }
                let duration = max(1.0, stagedDurationSeconds)
                let sourceVideoBps = stagedInfo.videoBitrateBps ?? sourceInfo?.videoBitrateBps ?? 0
                let targetVideoBps: Int = {
                    if sourceVideoBps > 0 {
                        let scaled = Int((sourceVideoBps * 0.80).rounded())
                        return min(max(2_500_000, scaled), 14_000_000)
                    }
                    return 6_000_000
                }()
                let targetAudioKbps = 160
                await MainActor.run {
                    self.appendActivityConsole("Hardware transcoding for compatibility (VideoToolbox)", source: "ffmpeg")
                    self.exportStatusText = "Transcoding for compatibility (hardware)…"
                    self.exportProgress = max(self.exportProgress, 0.61)
                }

                try? FileManager.default.removeItem(at: destinationURL)
                let hardwareArgs = [
                    "-y",
                    "-hide_banner",
                    "-loglevel", "error",
                    "-i", finalURL.path,
                    "-map", "0:v:0?",
                    "-c:v", "h264_videotoolbox",
                    "-b:v", "\(targetVideoBps)",
                    "-maxrate", "\(targetVideoBps)",
                    "-bufsize", "\(targetVideoBps * 2)",
                    "-pix_fmt", "yuv420p",
                    "-profile:v", "high",
                    "-map", "0:a:0?",
                    "-c:a", "aac",
                    "-b:a", "\(targetAudioKbps)k",
                    "-movflags", "+faststart",
                    destinationURL.path
                ]
                var transcodeError = await self.runFFmpegProcessWithProgress(
                    executableURL: ffmpegURL,
                    arguments: hardwareArgs,
                    durationSeconds: duration,
                    statusPrefix: "Hardware transcoding",
                    progressRange: 0.6...1.0
                )

                if transcodeError != nil {
                    await MainActor.run {
                        self.appendActivityConsole("Hardware encoder unavailable; falling back to software x264.", source: "ffmpeg")
                        self.exportStatusText = "Hardware unavailable, using software fallback…"
                        self.exportProgress = max(self.exportProgress, 0.65)
                    }
                    let softwareArgs = [
                        "-y",
                        "-hide_banner",
                        "-loglevel", "error",
                        "-i", finalURL.path,
                        "-map", "0:v:0?",
                        "-c:v", "libx264",
                        "-preset", "veryfast",
                        "-crf", "21",
                        "-pix_fmt", "yuv420p",
                        "-map", "0:a:0?",
                        "-c:a", "aac",
                        "-b:a", "\(targetAudioKbps)k",
                        "-movflags", "+faststart",
                        destinationURL.path
                    ]
                    transcodeError = await self.runFFmpegProcessWithProgress(
                        executableURL: ffmpegURL,
                        arguments: softwareArgs,
                        durationSeconds: duration,
                        statusPrefix: "Software fallback transcoding",
                        progressRange: 0.6...1.0
                    )
                }

                if let transcodeError {
                    await MainActor.run {
                        self.exportTask = nil
                        self.activeProcess = nil
                        self.isExporting = false
                        self.exportProgress = 0
                        self.exportStatusText = "Transcode failed: \(transcodeError)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                    }
                    return
                }
                finalURL = destinationURL
            }

            await MainActor.run {
                self.exportTask = nil
                self.activeProcess = nil
                self.isExporting = false
                self.exportProgress = 0

                if self.exportCancellationRequested {
                    self.exportStatusText = "Download cancelled"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .cancelled
                    return
                }

                self.setSource(finalURL)
                self.outputURL = finalURL
                let stageLabel = shouldSplitTranscodeStages ? "Download + transcode complete" : "Download complete"
                self.exportStatusText = "\(stageLabel): \(finalURL.lastPathComponent)"
                self.uiMessage = self.exportStatusText
                self.lastActivityState = .success
            }
        }
    }

    private func normalizedDownloadURL(from raw: String) -> URL? {
        if let parsed = URL(string: raw), let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return parsed
        }
        if let parsed = URL(string: "https://" + raw), let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return parsed
        }
        uiMessage = "Invalid URL. Please use an http(s) link."
        return nil
    }

    private func confirmTranscodeDownloadWarning() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This Download May Require Transcoding"
        alert.informativeText = "Best Available can require conversion to MP4, which may be slower and use more CPU."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func ytDLPFormatArguments(for preset: URLDownloadPreset) -> [String] {
        switch preset {
        case .compatibleBest:
            return [
                "-S", "res,codec:h264,aext:m4a",
                "-f", "bestvideo[ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4][vcodec^=avc1]/best[ext=mp4]"
            ]
        case .compatible1080:
            return [
                "-S", "res,codec:h264,aext:m4a",
                "-f", "bestvideo[height<=1080][ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=1080][ext=mp4][vcodec^=avc1]/best[height<=1080][ext=mp4]"
            ]
        case .compatible720:
            return [
                "-S", "res,codec:h264,aext:m4a",
                "-f", "bestvideo[height<=720][ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=720][ext=mp4][vcodec^=avc1]/best[height<=720][ext=mp4]"
            ]
        case .bestAnyToMP4:
            return [
                "-f", "bestvideo*+bestaudio/best"
            ]
        case .audioOnly:
            return [
                "-f", "bestaudio/best",
                "--extract-audio",
                "--audio-format", "mp3"
            ]
        }
    }

    private func defaultDownloadDirectoryURL() -> URL? {
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return downloads
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func defaultDownloadFileNameTemplate(for preset: URLDownloadPreset, sourceURL: URL) -> String {
        let host = (sourceURL.host ?? "download")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        // yt-dlp will expand title/id placeholders. Prefixing with host keeps source context.
        return "\(host) - %(title)s [%(id)s].\(preset.outputExtension)"
    }

    private func promptURLDownloadDestination(for preset: URLDownloadPreset, sourceURL: URL) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = false
        panel.allowedFileTypes = [preset.outputExtension]
        panel.nameFieldStringValue = defaultDownloadFileNameTemplate(for: preset, sourceURL: sourceURL)
        panel.title = "Save Downloaded Media"
        panel.prompt = "Save"
        if let defaultDirectory = defaultDownloadDirectoryURL() {
            panel.directoryURL = defaultDirectory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if url.pathExtension.isEmpty {
            return url.appendingPathExtension(preset.outputExtension)
        }
        return url
    }

    private func resolveURLDownloadDestination(for preset: URLDownloadPreset, sourceURL: URL) -> URL? {
        resolveURLDownloadDestination(
            for: preset,
            sourceURL: sourceURL,
            saveModeOverride: urlDownloadSaveLocationMode,
            customFolderPathOverride: customURLDownloadDirectoryPath
        )
    }

    private func resolveURLDownloadDestination(
        for preset: URLDownloadPreset,
        sourceURL: URL,
        saveModeOverride: URLDownloadSaveLocationMode,
        customFolderPathOverride: String?
    ) -> URL? {
        switch saveModeOverride {
        case .askEachTime:
            return promptURLDownloadDestination(for: preset, sourceURL: sourceURL)
        case .downloadsFolder:
            guard let folder = defaultDownloadDirectoryURL() else { return nil }
            return uniqueUnderscoreIndexedURL(
                in: folder,
                preferredFileName: defaultDownloadFileNameTemplate(for: preset, sourceURL: sourceURL)
            )
        case .customFolder:
            guard let customFolderPathOverride, !customFolderPathOverride.isEmpty else { return nil }
            let folder = URL(fileURLWithPath: customFolderPathOverride)
            guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
            return uniqueUnderscoreIndexedURL(
                in: folder,
                preferredFileName: defaultDownloadFileNameTemplate(for: preset, sourceURL: sourceURL)
            )
        }
    }

    func chooseCustomURLDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.urls.first {
            customURLDownloadDirectoryPath = url.path
        }
    }

    func setSource(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        if (isAnalyzing || isExporting) && sourceURL?.path != url.path {
            guard confirmReplaceSourceDuringActiveJob(newURL: url) else { return }
        }

        if isAnalyzing || isExporting {
            stopCurrentActivity()
        }

        waveformCache.removeAll(keepingCapacity: false)
        waveformCacheOrder.removeAll(keepingCapacity: false)
        clearQueuedJobs()

        sourceURL = url
        sourceSessionID = UUID()
        analysis = FileAnalysis(fileURL: url)
        sourceInfo = loadSourceMediaInfo(for: url)
        transcriptSegments = []
        hasCachedTranscript = false
        transcriptStatusText = hasAudioTrack ? "No transcript generated yet." : "No audio track available for transcript."
        isGeneratingTranscript = false
        clipEncodingMode = hasVideoTrack ? defaultClipEncodingMode : .audioOnly
        applySuggestedClipBitrateFromSource()
        outputURL = nil
        uiMessage = "Loaded \(url.lastPathComponent)"
        wasCancelled = false
        analyzeProgress = 0
        exportProgress = 0
        captureTimelineMarkers = []
        highlightedCaptureTimelineMarkerID = nil
        highlightedClipBoundary = nil
        clipPlayheadSeconds = 0
        clearActivityConsole()
        resetClipRange()
    }

    private func confirmReplaceSourceDuringActiveJob(newURL: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace Current File?"
        let activeTask = isAnalyzing ? "analysis" : "export"
        alert.informativeText = "A \(activeTask) is currently running. Replacing the file will stop the current job and load “\(newURL.lastPathComponent)”."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func clearSource() {
        if isAnalyzing || isExporting {
            stopCurrentActivity()
        }
        sourceURL = nil
        sourceSessionID = UUID()
        analysis = nil
        sourceInfo = nil
        transcriptSegments = []
        hasCachedTranscript = false
        transcriptStatusText = "No transcript generated yet."
        isGeneratingTranscript = false
        waveformCache.removeAll(keepingCapacity: false)
        waveformCacheOrder.removeAll(keepingCapacity: false)
        clearQueuedJobs()
        outputURL = nil
        captureTimelineMarkers = []
        highlightedCaptureTimelineMarkerID = nil
        highlightedClipBoundary = nil
        clipPlayheadSeconds = 0
        clearActivityConsole()
        uiMessage = "Ready"
        resetClipRange()
    }

    func clearActivityConsole() {
        activityConsoleText = ""
    }

    func copyActivityConsole() {
        guard !activityConsoleText.isEmpty else { return }
        copyToClipboard(activityConsoleText)
    }

    func appendActivityConsole(_ line: String, source: String? = nil) {
        let cleaned = line.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .newlines)
        guard !cleaned.isEmpty else { return }

        let renderedLine: String
        if let source, !source.isEmpty {
            renderedLine = "[\(source)] \(cleaned)"
        } else {
            renderedLine = cleaned
        }

        if activityConsoleText.isEmpty {
            activityConsoleText = renderedLine
        } else {
            activityConsoleText += "\n" + renderedLine
        }

        if activityConsoleText.count > maxActivityConsoleCharacters {
            let trimCount = activityConsoleText.count - activityConsoleTrimCharacters
            if trimCount > 0 {
                let start = activityConsoleText.index(activityConsoleText.startIndex, offsetBy: trimCount)
                activityConsoleText = String(activityConsoleText[start...])
            }
        }
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

    func generateTranscriptFromInspect() {
        guard let url = sourceURL else { return }
        guard !hasCachedTranscript else { return }
        guard hasAudioTrack else {
            transcriptStatusText = "No audio track available for transcript."
            return
        }
        guard whisperTranscriptionAvailable else {
            transcriptStatusText = "Whisper binary/model is not bundled in this app build."
            return
        }
        guard !isAnalyzing && !isExporting && !isGeneratingTranscript else { return }

        _ = beginDirectJobTracking(
            fileName: url.lastPathComponent,
            summary: "Generate Transcript",
            subtitle: "Whisper"
        )

        isGeneratingTranscript = true
        isAnalyzing = true
        lastActivityState = .running
        wasCancelled = false
        analyzeProgress = 0
        clearActivityConsole()
        appendActivityConsole("Transcript generation started", source: "analysis")
        analyzePhaseText = "Transcribing audio"
        updateAnalyzeStatusText(fileName: url.lastPathComponent, progress: 0)
        transcriptStatusText = "Generating transcript…"
        uiMessage = transcriptStatusText
        cancelFlag.reset()

        analyzeTask = Task { [weak self] in
            guard let self else { return }
            let flag = cancelFlag
            let result = await Task.detached(priority: .userInitiated) {
                transcribeAudioWithWhisper(
                    file: url,
                    shouldCancel: {
                        flag.isCancelled()
                    },
                    progressHandler: { progress in
                        Task { @MainActor [weak self] in
                            self?.setAnalyzeProgress(progress, fileName: url.lastPathComponent)
                        }
                    },
                    onConsoleOutput: { line, source in
                        Task { @MainActor [weak self] in
                            self?.appendActivityConsole(line, source: source)
                        }
                    }
                )
            }.value

            await MainActor.run {
                self.applyTranscriptGenerationResult(result)
            }
        }
    }

    private func transcriptPlainText() -> String {
        transcriptSegments
            .map { $0.formatted }
            .joined(separator: "\n")
    }

    private func srtTimestamp(_ seconds: Double) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        let hours = Int(safe / 3600)
        let minutes = Int((safe.truncatingRemainder(dividingBy: 3600)) / 60)
        let wholeSeconds = Int(safe.truncatingRemainder(dividingBy: 60))
        let millis = Int((safe - floor(safe)) * 1000.0)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, wholeSeconds, millis)
    }

    private func transcriptSRT() -> String {
        transcriptSegments.enumerated().map { index, segment in
            let text = segment.text.replacingOccurrences(of: "\r\n", with: "\n")
            return """
            \(index + 1)
            \(srtTimestamp(segment.start)) --> \(srtTimestamp(segment.end))
            \(text)
            """
        }
        .joined(separator: "\n\n") + "\n"
    }

    func exportTranscriptFromInspect() {
        guard let sourceURL else { return }
        guard !transcriptSegments.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedFileTypes = ["txt", "srt"]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "_transcript.txt"
        panel.message = "Export transcript as TXT or SRT"
        panel.prompt = "Export"

        let formatLabel = NSTextField(labelWithString: "Format:")
        formatLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.addItems(withTitles: ["Plain Text (.txt)", "SubRip (.srt)"])
        formatPopup.selectItem(at: 0)
        formatPopup.controlSize = .small
        formatPopup.frame.size.width = 150

        let rowStack = NSStackView(views: [formatLabel, formatPopup])
        rowStack.orientation = .horizontal
        rowStack.alignment = .firstBaseline
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let accessoryContainer = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 30))
        accessoryContainer.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: accessoryContainer.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(lessThanOrEqualTo: accessoryContainer.trailingAnchor, constant: -8),
            rowStack.centerYAnchor.constraint(equalTo: accessoryContainer.centerYAnchor)
        ])
        panel.accessoryView = accessoryContainer

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let selectedExtension = formatPopup.indexOfSelectedItem == 1 ? "srt" : "txt"
        let resolvedDestination: URL = {
            if destination.pathExtension.lowercased() == selectedExtension {
                return destination
            }
            return destination.deletingPathExtension().appendingPathExtension(selectedExtension)
        }()

        let ext = selectedExtension
        let content: String
        switch ext {
        case "srt":
            content = transcriptSRT()
        case "txt", "":
            content = transcriptPlainText()
        default:
            uiMessage = "Transcript export failed: Unsupported format \(ext)"
            lastActivityState = .failed
            notifyCompletion("Transcript Export Failed", message: uiMessage)
            return
        }

        do {
            try content.write(to: resolvedDestination, atomically: true, encoding: .utf8)
            outputURL = resolvedDestination
            uiMessage = "Transcript exported to \(resolvedDestination.lastPathComponent)"
            lastActivityState = .success
            if let soundName = completionSound.soundName,
               let sound = NSSound(named: soundName) {
                sound.play()
            }
            notifyCompletion("Transcript Export Complete", message: uiMessage)
        } catch {
            uiMessage = "Transcript export failed: \(error.localizedDescription)"
            lastActivityState = .failed
            notifyCompletion("Transcript Export Failed", message: uiMessage)
        }
    }

    func resetProfanityWordsToDefaults() {
        profanityWordsText = defaultProfanityWordsStorageString
    }

    func addProfanityWords(from raw: String) {
        let additions = profanityWordsFromString(raw)
        guard !additions.isEmpty else { return }
        let merged = selectedProfanityWords.union(additions)
        profanityWordsText = merged.sorted().joined(separator: ", ")
    }

    func removeProfanityWord(_ word: String) {
        let token = normalizedToken(word)
        guard !token.isEmpty else { return }
        var words = selectedProfanityWords
        words.remove(token)
        profanityWordsText = words.sorted().joined(separator: ", ")
    }

    func resetAdvancedClipFilenameTemplateToDefaults() {
        advancedClipFilenamePreset = .sourceClipInOut
    }

    private func advancedClipFilenameBase(
        sourceName: String,
        startSeconds: Double,
        endSeconds: Double,
        codec: String,
        resolution: String
    ) -> String {
        let tcStart = formatSeconds(startSeconds).replacingOccurrences(of: ":", with: "-")
        let tcEnd = formatSeconds(endSeconds).replacingOccurrences(of: ":", with: "-")
        let duration = String(format: "%.3f", max(0, endSeconds - startSeconds))

        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH-mm-ss"

        let replacements: [String: String] = [
            "{source_name}": sanitizeFilenameComponent(sourceName),
            "{in_tc}": sanitizeFilenameComponent(tcStart),
            "{out_tc}": sanitizeFilenameComponent(tcEnd),
            "{duration}": sanitizeFilenameComponent(duration),
            "{date}": dateFormatter.string(from: now),
            "{time}": timeFormatter.string(from: now),
            "{codec}": sanitizeFilenameComponent(codec.lowercased()),
            "{resolution}": sanitizeFilenameComponent(resolution.lowercased().replacingOccurrences(of: " ", with: ""))
        ]

        var rendered = advancedClipFilenameTemplate
        for (token, value) in replacements {
            rendered = rendered.replacingOccurrences(of: token, with: value)
        }
        rendered = sanitizeFilenameComponent(rendered)
        if rendered.isEmpty {
            rendered = "\(sanitizeFilenameComponent(sourceName))_clip_\(tcStart)_to_\(tcEnd)"
        }
        return rendered
    }

    private func applyClipRange(start: Double, end: Double) {
        let duration = sourceDurationSeconds
        clipStartSeconds = min(max(0, start), duration)
        clipEndSeconds = min(max(0, end), duration)
        if clipEndSeconds < clipStartSeconds {
            clipEndSeconds = clipStartSeconds
        }
        clipStartText = formatSeconds(clipStartSeconds)
        clipEndText = formatSeconds(clipEndSeconds)
    }

    private func syncClipTextFields() {
        clipStartText = formatSeconds(clipStartSeconds)
        clipEndText = formatSeconds(clipEndSeconds)
    }

    private func setClipRangeWithUndo(
        start: Double,
        end: Double,
        undoManager: UndoManager?,
        actionName: String
    ) {
        let previousStart = clipStartSeconds
        let previousEnd = clipEndSeconds
        applyClipRange(start: start, end: end)
        let didChange = abs(previousStart - clipStartSeconds) > 0.0001 || abs(previousEnd - clipEndSeconds) > 0.0001
        guard didChange, let undoManager else { return }
        let undoStart = previousStart
        let undoEnd = previousEnd
        undoManager.registerUndo(withTarget: self) { target in
            target.setClipRangeWithUndo(
                start: undoStart,
                end: undoEnd,
                undoManager: undoManager,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
    }

    func resetClipRange(undoManager: UndoManager? = nil) {
        let duration = max(0, sourceInfo?.durationSeconds ?? analysis?.mediaDuration ?? 0)
        setClipRangeWithUndo(start: 0, end: duration, undoManager: undoManager, actionName: "Clear Clip In/Out")
    }

    private func applySuggestedClipBitrateFromSource() {
        let step = 0.5
        let sliderMin = 0.5
        let sliderMax = 20.0

        let suggested: Double
        if let sourceVideoBps = sourceInfo?.videoBitrateBps, sourceVideoBps > 0 {
            let sourceMbps = sourceVideoBps / 1_000_000.0
            let nearestTick = (sourceMbps / step).rounded() * step
            suggested = nearestTick + step
        } else {
            suggested = 4.0
        }

        originalModeDefaultBitrateMbps = min(sliderMax, max(sliderMin, suggested))
        if clipCompatibleMaxResolution == .original {
            clipVideoBitrateMbps = originalModeDefaultBitrateMbps
        }
    }

    private func applySuggestedCompatibleBitrateForResolution() {
        // Only auto-adjust when user selects a capped resolution.
        let suggested: Double
        switch clipCompatibleMaxResolution {
        case .original:
            suggested = originalModeDefaultBitrateMbps
        case .p1080:
            suggested = 8.0
        case .p720:
            suggested = 5.0
        case .p480:
            suggested = 2.5
        }

        clipVideoBitrateMbps = min(20.0, max(0.5, suggested))
    }

    private func preferredAudioTrackIndex(for asset: AVAsset) -> Int? {
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return nil }

        // Prefer the highest-bitrate audio track; this is usually the primary program audio.
        var bestIndex = 0
        var bestScore = audioTracks[0].estimatedDataRate
        for (index, track) in audioTracks.enumerated() {
            let score = track.estimatedDataRate
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return bestIndex
    }

    func clampClipRange() {
        applyClipRange(start: clipStartSeconds, end: clipEndSeconds)
    }

    func commitClipStartText(undoManager: UndoManager? = nil) {
        guard let parsed = parseTimecode(clipStartText) else {
            clipStartText = formatSeconds(clipStartSeconds)
            return
        }
        setClipStart(parsed, undoManager: undoManager)
    }

    func commitClipEndText(undoManager: UndoManager? = nil) {
        guard let parsed = parseTimecode(clipEndText) else {
            clipEndText = formatSeconds(clipEndSeconds)
            return
        }
        setClipEnd(parsed, undoManager: undoManager)
    }

    func setClipStart(_ time: Double, undoManager: UndoManager? = nil) {
        setClipRangeWithUndo(
            start: time,
            end: clipEndSeconds,
            undoManager: undoManager,
            actionName: "Set Clip Start"
        )
    }

    func setClipEnd(_ time: Double, undoManager: UndoManager? = nil) {
        setClipRangeWithUndo(
            start: clipStartSeconds,
            end: time,
            undoManager: undoManager,
            actionName: "Set Clip End"
        )
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard let provider = accepted.first else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.setSource(url)
            }
        }
        return true
    }

    func startAnalysis(queueJobID: UUID? = nil) {
        if queueJobID == nil && (isAnalyzing || isExporting || isGeneratingTranscript) {
            enqueueCurrentAnalysis()
            return
        }
        guard canRequestAnalyze, let url = sourceURL else {
            completeQueuedJobIfNeeded(queueJobID, status: .failed, message: "Unable to start analysis.")
            return
        }

        let requestedBlack = effectiveAnalyzeBlackFrames
        let requestedSilence = effectiveAnalyzeAudioSilence
        let requestedProfanity = effectiveAnalyzeProfanity
        let requestedProfanityWordsSnapshot = normalizedProfanityWordsStorageString(profanityWordsText)
        let requestedProfanityWordsSet = selectedProfanityWords
        let cachedTranscript = hasCachedTranscript ? transcriptSegments : nil

        let previous = analysis
        let hasCompletedPrevious: Bool
        if let previous {
            if case .done = previous.status {
                hasCompletedPrevious = true
            } else {
                hasCompletedPrevious = false
            }
        } else {
            hasCompletedPrevious = false
        }

        let hasCachedBlack = hasCompletedPrevious && (previous?.includedBlackDetection == true)
        let hasCachedSilence = hasCompletedPrevious
            && (previous?.includedSilenceDetection == true)
            && abs((previous?.silenceMinDurationSeconds ?? 0) - silenceMinDurationSeconds) < 0.0001
        let hasCachedProfanity = hasCompletedPrevious
            && (previous?.includedProfanityDetection == true)
            && (previous?.profanityWordsSnapshot == requestedProfanityWordsSnapshot)

        let runBlack = requestedBlack && !hasCachedBlack
        let runSilence = requestedSilence && !hasCachedSilence
        let runProfanity = requestedProfanity && !hasCachedProfanity

        let cachedBlackSegments: [Segment] = requestedBlack && hasCachedBlack ? (previous?.segments ?? []) : []
        let cachedSilentSegments: [Segment] = requestedSilence && hasCachedSilence ? (previous?.silentSegments ?? []) : []
        let cachedProfanityHits: [ProfanityHit] = requestedProfanity && hasCachedProfanity ? (previous?.profanityHits ?? []) : []

        if !runBlack && !runSilence && !runProfanity {
            analysis = FileAnalysis(
                fileURL: url,
                segments: cachedBlackSegments,
                silentSegments: cachedSilentSegments,
                profanityHits: cachedProfanityHits,
                includedBlackDetection: requestedBlack,
                includedSilenceDetection: requestedSilence,
                includedProfanityDetection: requestedProfanity,
                profanityWordsSnapshot: requestedProfanityWordsSnapshot,
                silenceMinDurationSeconds: silenceMinDurationSeconds,
                mediaDuration: sourceInfo?.durationSeconds ?? previous?.mediaDuration,
                progress: 1.0,
                status: .done
            )
            analyzeProgress = 0
            analyzeStatusText = "Using cached analysis results."
            uiMessage = analysis?.summary ?? "Using cached analysis results."
            lastActivityState = .success
            completeQueuedJobIfNeeded(queueJobID, status: .completed, message: uiMessage)
            return
        }

        if queueJobID == nil {
            _ = beginDirectJobTracking(
                fileName: url.lastPathComponent,
                summary: analysisJobTitle(
                    black: requestedBlack,
                    silence: requestedSilence,
                    profanity: requestedProfanity
                ),
                subtitle: analysisJobSubtitle(
                    black: requestedBlack,
                    silence: requestedSilence,
                    profanity: requestedProfanity
                )
            )
        }

        isAnalyzing = true
        lastActivityState = .running
        wasCancelled = false
        analyzeProgress = 0
        clearActivityConsole()
        appendActivityConsole("Analysis started", source: "analysis")
        analyzePhaseText = "Preparing analysis"
        updateAnalyzeStatusText(fileName: url.lastPathComponent, progress: 0)
        cancelFlag.reset()

        let knownDuration = sourceInfo?.durationSeconds

        if var existing = analysis {
            existing.status = .running
            existing.progress = 0
            existing.segments = runBlack ? [] : cachedBlackSegments
            existing.silentSegments = runSilence ? [] : cachedSilentSegments
            existing.profanityHits = runProfanity ? [] : cachedProfanityHits
            existing.includedBlackDetection = requestedBlack
            existing.includedSilenceDetection = requestedSilence
            existing.includedProfanityDetection = requestedProfanity
            existing.profanityWordsSnapshot = requestedProfanityWordsSnapshot
            existing.silenceMinDurationSeconds = silenceMinDurationSeconds
            existing.mediaDuration = knownDuration
            analysis = existing
        } else {
            analysis = FileAnalysis(
                fileURL: url,
                segments: runBlack ? [] : cachedBlackSegments,
                silentSegments: runSilence ? [] : cachedSilentSegments,
                profanityHits: runProfanity ? [] : cachedProfanityHits,
                includedBlackDetection: requestedBlack,
                includedSilenceDetection: requestedSilence,
                includedProfanityDetection: requestedProfanity,
                profanityWordsSnapshot: requestedProfanityWordsSnapshot,
                silenceMinDurationSeconds: silenceMinDurationSeconds,
                mediaDuration: knownDuration,
                status: .running
            )
        }

        analyzeTask = Task { [weak self] in
            guard let self else { return }
            let flag = cancelFlag
            let detectBlack = runBlack
            let detectSilence = runSilence
            let detectProfanity = runProfanity
            let silenceMinDuration = self.silenceMinDurationSeconds
            let profanityWords = requestedProfanityWordsSet
            let result = await Task.detached(priority: .userInitiated) {
                runDetection(
                    file: url,
                    detectBlackFrames: detectBlack,
                    detectAudioSilence: detectSilence,
                    detectProfanity: detectProfanity,
                    profanityWords: profanityWords,
                    cachedTranscriptSegments: cachedTranscript,
                    silenceMinDuration: silenceMinDuration,
                    onStatusUpdate: { status in
                        Task { @MainActor [weak self] in
                            self?.setAnalyzePhase(status, fileName: url.lastPathComponent)
                        }
                    },
                    onBlackSegmentDetected: { segment in
                        Task { @MainActor [weak self] in
                            self?.appendDetectedBlackSegment(segment)
                        }
                    },
                    onSilentSegmentDetected: { segment in
                        Task { @MainActor [weak self] in
                            self?.appendDetectedSilentSegment(segment)
                        }
                    },
                    onProfanityDetected: { hit in
                        Task { @MainActor [weak self] in
                            self?.appendDetectedProfanityHit(hit)
                        }
                    },
                    onConsoleOutput: { line, source in
                        Task { @MainActor [weak self] in
                            self?.appendActivityConsole(line, source: source)
                        }
                    }
                ) { progress in
                    Task { @MainActor [weak self] in
                        self?.setAnalyzeProgress(progress, fileName: url.lastPathComponent)
                    }
                } shouldCancel: {
                    flag.isCancelled()
                }
            }.value

            self.applyAnalysisResult(
                result,
                includedBlack: requestedBlack,
                includedSilence: requestedSilence,
                includedProfanity: requestedProfanity,
                ranBlack: runBlack,
                ranSilence: runSilence,
                ranProfanity: runProfanity,
                cachedBlackSegments: cachedBlackSegments,
                cachedSilentSegments: cachedSilentSegments,
                cachedProfanityHits: cachedProfanityHits,
                profanityWordsSnapshot: requestedProfanityWordsSnapshot
            )
            switch result {
            case .success:
                self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.uiMessage)
            case .failure(.cancelled):
                self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.uiMessage)
            case .failure:
                self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.uiMessage)
            }
        }
    }

    func stopAnalysis() {
        guard isAnalyzing else { return }
        cancelFlag.cancel()
        analyzeTask?.cancel()
    }

    private func setAnalyzeProgress(_ progress: Double, fileName: String) {
        let clamped = min(1, max(0, progress))
        analyzeProgress = clamped
        updateAnalyzeStatusText(fileName: fileName, progress: clamped)
        if var current = analysis {
            current.progress = clamped
            analysis = current
        }
    }

    private func setAnalyzePhase(_ phase: String, fileName: String) {
        analyzePhaseText = phase
        updateAnalyzeStatusText(fileName: fileName, progress: analyzeProgress)
    }

    private func updateAnalyzeStatusText(fileName: String, progress: Double) {
        let percent = Int((min(1, max(0, progress)) * 100).rounded())
        analyzeStatusText = "\(analyzePhaseText)… \(percent)%"
    }

    private func appendDetectedBlackSegment(_ segment: Segment) {
        guard var current = analysis else { return }
        guard case .running = current.status else { return }
        if !containsSegment(current.segments, segment) {
            current.segments.append(segment)
            analysis = current
        }
    }

    private func appendDetectedSilentSegment(_ segment: Segment) {
        guard var current = analysis else { return }
        guard case .running = current.status else { return }
        if !containsSegment(current.silentSegments, segment) {
            current.silentSegments.append(segment)
            analysis = current
        }
    }

    private func appendDetectedProfanityHit(_ hit: ProfanityHit) {
        guard var current = analysis else { return }
        guard case .running = current.status else { return }
        if !current.profanityHits.contains(where: {
            abs($0.start - hit.start) < 0.001 &&
            abs($0.end - hit.end) < 0.001 &&
            $0.word == hit.word
        }) {
            current.profanityHits.append(hit)
            analysis = current
        }
    }

    private func containsSegment(_ list: [Segment], _ candidate: Segment) -> Bool {
        list.contains {
            abs($0.start - candidate.start) < 0.001 &&
            abs($0.end - candidate.end) < 0.001
        }
    }

    private func applyAnalysisResult(
        _ result: Result<DetectionOutput, DetectionError>,
        includedBlack: Bool,
        includedSilence: Bool,
        includedProfanity: Bool,
        ranBlack: Bool,
        ranSilence: Bool,
        ranProfanity: Bool,
        cachedBlackSegments: [Segment],
        cachedSilentSegments: [Segment],
        cachedProfanityHits: [ProfanityHit],
        profanityWordsSnapshot: String
    ) {
        isAnalyzing = false
        isGeneratingTranscript = false
        analyzeTask = nil
        analyzeProgress = 0
        analyzePhaseText = "Preparing analysis"

        guard var current = analysis else { return }
        switch result {
        case .success(let output):
            current.segments = ranBlack ? output.segments : cachedBlackSegments
            current.silentSegments = ranSilence ? output.silentSegments : cachedSilentSegments
            current.profanityHits = ranProfanity ? output.profanityHits : cachedProfanityHits
            current.includedBlackDetection = includedBlack
            current.includedSilenceDetection = includedSilence
            current.includedProfanityDetection = includedProfanity
            current.profanityWordsSnapshot = profanityWordsSnapshot
            current.mediaDuration = output.mediaDuration
            current.progress = 1
            current.status = .done
            analysis = current
            if includedProfanity, let transcript = output.transcriptSegments {
                transcriptSegments = transcript
                hasCachedTranscript = true
                transcriptStatusText = transcript.isEmpty ? "Transcript generated (no speech detected)." : "Transcript generated (\(transcript.count) segment(s))."
            }
            if current.segments.isEmpty && current.silentSegments.isEmpty && current.profanityHits.isEmpty {
                var noneParts: [String] = []
                if includedBlack { noneParts.append("black segments") }
                if includedSilence { noneParts.append("silent gaps") }
                if includedProfanity { noneParts.append("profanity") }
                uiMessage = noneParts.isEmpty ? "No analysis type enabled." : "No \(noneParts.joined(separator: ", ")) found."
            } else {
                var parts: [String] = []
                if includedBlack {
                    if current.segments.isEmpty {
                        parts.append("No black segments")
                    } else {
                        parts.append("\(current.segments.count) black segment(s)")
                    }
                }
                if includedSilence {
                    if current.silentSegments.isEmpty {
                        parts.append("No silent gaps")
                    } else {
                        parts.append("\(current.silentSegments.count) silent gap(s)")
                    }
                }
                if includedProfanity {
                    if current.profanityHits.isEmpty {
                        parts.append("No profanity")
                    } else {
                        parts.append("\(current.profanityHits.count) profanity hit(s)")
                    }
                }
                uiMessage = "Detected: " + parts.joined(separator: ", ")
            }
            analyzeStatusText = uiMessage
            lastActivityState = .success
            if let soundName = completionSound.soundName,
               let sound = NSSound(named: soundName) {
                sound.play()
            }
            notifyCompletion("Black Frame Analysis Complete", message: uiMessage)
        case .failure(.cancelled):
            current.status = .failed("Stopped")
            analysis = current
            wasCancelled = true
            analyzeStatusText = "Analysis stopped"
            uiMessage = "Analysis stopped"
            lastActivityState = .cancelled
            notifyCompletion("Black Frame Analysis Stopped", message: uiMessage)
        case .failure(.failed(let reason)):
            current.status = .failed(reason)
            analysis = current
            analyzeStatusText = "Analysis failed"
            uiMessage = "Analysis failed: \(reason)"
            lastActivityState = .failed
            notifyCompletion("Black Frame Analysis Failed", message: uiMessage)
        }
    }

    private func applyTranscriptGenerationResult(
        _ result: Result<[TranscriptSegment], DetectionError>
    ) {
        isGeneratingTranscript = false
        isAnalyzing = false
        analyzeTask = nil
        analyzeProgress = 0
        analyzePhaseText = "Preparing analysis"

        switch result {
        case .success(let transcript):
            transcriptSegments = transcript
            hasCachedTranscript = true
            if transcript.isEmpty {
                transcriptStatusText = "Transcript generated (no speech detected)."
            } else {
                transcriptStatusText = "Transcript generated (\(transcript.count) segment(s))."
            }
            analyzeStatusText = transcriptStatusText
            uiMessage = transcriptStatusText
            lastActivityState = .success
            if let soundName = completionSound.soundName,
               let sound = NSSound(named: soundName) {
                sound.play()
            }
            notifyCompletion("Transcript Complete", message: transcriptStatusText)
            completeQueuedJobIfNeeded(nil, status: .completed, message: transcriptStatusText)
        case .failure(.cancelled):
            transcriptStatusText = "Transcript generation stopped."
            analyzeStatusText = transcriptStatusText
            uiMessage = transcriptStatusText
            lastActivityState = .cancelled
            notifyCompletion("Transcript Stopped", message: transcriptStatusText)
            completeQueuedJobIfNeeded(nil, status: .cancelled, message: transcriptStatusText)
        case .failure(.failed(let reason)):
            transcriptStatusText = "Transcript failed: \(reason)"
            analyzeStatusText = "Transcript generation failed"
            uiMessage = transcriptStatusText
            lastActivityState = .failed
            notifyCompletion("Transcript Failed", message: transcriptStatusText)
            completeQueuedJobIfNeeded(nil, status: .failed, message: transcriptStatusText)
        }

    }

    private func stopExport() {
        guard isExporting else { return }
        let queueJobID = activeQueuedJobID
        exportCancellationRequested = true
        activeClipExportRunToken = nil
        activeExportSession?.cancelExport()
        if let process = activeProcess, process.isRunning {
            process.terminate()
        }
        exportTask?.cancel()
        exportTask = nil
        activeExportSession = nil
        activeProcess = nil
        isExporting = false
        exportProgress = 0
        exportStatusText = "Export cancelled"
        uiMessage = exportStatusText
        lastActivityState = .cancelled
        completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: "Stopped by user.")
    }

    func startExport(queueJobID: UUID? = nil, preselectedDestination: URL? = nil) {
        if queueJobID == nil && (isAnalyzing || isExporting || isGeneratingTranscript) {
            enqueueCurrentAudioExport()
            return
        }
        guard canRequestAudioExport, let sourceURL else {
            completeQueuedJobIfNeeded(queueJobID, status: .failed, message: "Unable to start audio export.")
            return
        }

        let destination: URL
        if let preselectedDestination {
            destination = preselectedDestination
        } else {
            guard let chosenDestination = promptAudioExportDestination(for: sourceURL) else {
                completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: "Save cancelled.")
                return
            }
            destination = chosenDestination
        }

        if queueJobID == nil {
            _ = beginDirectJobTracking(
                fileName: sourceURL.lastPathComponent,
                summary: audioExportJobTitle(format: selectedAudioFormat),
                subtitle: audioExportJobSubtitle(bitrateKbps: exportAudioBitrateKbps)
            )
        }

        isExporting = true
        lastActivityState = .running
        exportCancellationRequested = false
        exportProgress = 0
        clearActivityConsole()
        appendActivityConsole("Audio export started", source: "export")
        exportStatusText = "Preparing export…"
        outputURL = nil

        let asset = AVURLAsset(url: sourceURL)
        try? FileManager.default.removeItem(at: destination)

        exportTask = Task { [weak self] in
            guard let self else { return }

            if self.selectedAudioFormat == .m4a {
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    await MainActor.run {
                        self.exportTask = nil
                        self.isExporting = false
                        self.exportStatusText = "Export failed: Unable to create export session"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    }
                    return
                }
                await MainActor.run {
                    self.activeExportSession = session
                }

                session.outputURL = destination
                session.outputFileType = .m4a
                session.shouldOptimizeForNetworkUse = true

                let monitor = Task { [weak self] in
                    while session.status == .waiting || session.status == .exporting {
                        await MainActor.run {
                            self?.exportProgress = Double(session.progress)
                            self?.exportStatusText = "Exporting M4A… \(Int((Double(session.progress) * 100).rounded()))%"
                        }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }

                await withCheckedContinuation { continuation in
                    session.exportAsynchronously {
                        continuation.resume()
                    }
                }

                monitor.cancel()

                await MainActor.run {
                    self.exportTask = nil
                    self.activeExportSession = nil
                    self.isExporting = false
                    self.exportProgress = 0

                    if self.exportCancellationRequested {
                        self.exportStatusText = "Export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                        self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                        return
                    }

                    switch session.status {
                    case .completed:
                        self.outputURL = destination
                        self.exportStatusText = "Export complete: \(destination.lastPathComponent)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .success
                        self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.exportStatusText, outputURL: destination)
                    case .failed:
                        self.exportStatusText = "Export failed: \(session.error?.localizedDescription ?? "Unknown error")"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    case .cancelled:
                        self.exportStatusText = "Export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                        self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                    default:
                        self.exportStatusText = "Export ended with status: \(session.status.rawValue)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    }
                }
                return
            }

            await MainActor.run {
                self.exportProgress = 0.1
                self.exportStatusText = "Encoding MP3…"
            }

            let mp3Error: String?
            if let ffmpegURL = self.findFFmpegExecutable() {
                mp3Error = await self.runFFmpegProcessWithProgress(
                    executableURL: ffmpegURL,
                    arguments: [
                        "-y",
                        "-hide_banner",
                        "-loglevel", "error",
                        "-i", sourceURL.path,
                        "-vn",
                        "-acodec", "libmp3lame",
                        "-b:a", "\(max(64, self.exportAudioBitrateKbps))k",
                        destination.path
                    ],
                    durationSeconds: max(0.001, self.sourceDurationSeconds),
                    statusPrefix: "Encoding MP3"
                )
            } else {
                mp3Error = "No ffmpeg executable found. Bundle ffmpeg at Contents/Resources/ffmpeg or install it on this Mac."
            }

            await MainActor.run {
                self.exportTask = nil
                self.isExporting = false
                self.exportProgress = 0
                if self.exportCancellationRequested {
                    self.exportStatusText = "Export cancelled"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .cancelled
                    self.notifyCompletion("MP3 Export Stopped", message: self.exportStatusText)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                    return
                }
                if let mp3Error {
                    self.exportStatusText = "MP3 export failed: \(mp3Error)"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                    self.notifyCompletion("MP3 Export Failed", message: self.exportStatusText)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                } else {
                    self.outputURL = destination
                    self.exportStatusText = "Export complete: \(destination.lastPathComponent)"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .success
                    self.notifyCompletion("MP3 Export Complete", message: self.exportStatusText)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.exportStatusText, outputURL: destination)
                }
            }
        }
    }

    func startClipExport(skipSaveDialog: Bool = false, queueJobID: UUID? = nil, preselectedDestination: URL? = nil) {
        func finalizeQueued(_ status: ClipExportQueueStatus, _ message: String? = nil) {
            completeQueuedJobIfNeeded(queueJobID, status: status, message: message)
        }

        if queueJobID == nil && (isAnalyzing || isExporting || isGeneratingTranscript) {
            enqueueCurrentClipExport(skipSaveDialog: skipSaveDialog)
            return
        }

        guard canRequestClipExport, let sourceURL else {
            finalizeQueued(.failed, "Unable to start export.")
            return
        }
        if !hasVideoTrack && clipEncodingMode != .audioOnly {
            clipEncodingMode = .audioOnly
        }

        clampClipRange()
        guard clipDurationSeconds > 0 else {
            finalizeQueued(.failed, "Invalid clip duration.")
            return
        }

        let defaultName = defaultClipExportFileName(for: sourceURL)

        let destination: URL
        if let preselectedDestination {
            destination = preselectedDestination
            try? FileManager.default.removeItem(at: destination)
        } else if skipSaveDialog {
            let sourceDirectory = sourceURL.deletingLastPathComponent()
            destination = uniqueUnderscoreIndexedURL(in: sourceDirectory, preferredFileName: defaultName)
        } else {
            guard let chosenDestination = promptClipExportDestination(for: sourceURL, defaultName: defaultName) else {
                finalizeQueued(.cancelled, "Save cancelled.")
                return
            }
            destination = chosenDestination
            try? FileManager.default.removeItem(at: destination)
        }

        if queueJobID == nil {
            let formatLabel = clipEncodingMode == .audioOnly ? clipAudioOnlyFormat.rawValue : selectedClipFormat.rawValue
            let summary = clipJobTitle(skipSaveDialog: skipSaveDialog, mode: clipEncodingMode)
            let subtitle = clipJobSubtitle(
                mode: clipEncodingMode,
                format: formatLabel,
                startSeconds: clipStartSeconds,
                endSeconds: clipEndSeconds
            )
            _ = beginDirectJobTracking(
                fileName: sourceURL.lastPathComponent,
                summary: summary,
                subtitle: subtitle
            )
        }

        if skipSaveDialog && queueJobID == nil {
            DispatchQueue.main.async { [weak self] in
                self?.quickExportFlashToken &+= 1
            }
            playQuickExportSnipSound()
        }

        let exportRunToken = UUID()
        activeClipExportRunToken = exportRunToken
        isExporting = true
        lastActivityState = .running
        exportCancellationRequested = false
        exportProgress = 0
        clearActivityConsole()
        appendActivityConsole(skipSaveDialog ? "Quick clip export started" : "Clip export started", source: "export")
        exportStatusText = queueJobID != nil ? "Running queued clip export…" : (skipSaveDialog ? "Quick exporting clip…" : "Exporting clip…")
        outputURL = nil

        if clipEncodingMode == .audioOnly {
            exportTask = Task { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.exportProgress = 0.1
                    self.exportStatusText = "Exporting audio-only clip…"
                }

                guard let ffmpegURL = self.findFFmpegExecutable() else {
                    await MainActor.run {
                        guard self.activeClipExportRunToken == exportRunToken else { return }
                        self.activeClipExportRunToken = nil
                        self.exportTask = nil
                        self.isExporting = false
                        self.exportProgress = 0
                        self.exportStatusText = "Clip export failed: No ffmpeg executable found."
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    }
                    return
                }

                let start = String(format: "%.3f", self.clipStartSeconds)
                let clipDuration = max(0.001, self.clipEndSeconds - self.clipStartSeconds)
                let durationStr = String(format: "%.3f", clipDuration)
                let bitrateKbps = min(max(64, self.clipAudioBitrateKbps), 320)
                let fadeDuration = min(0.333, clipDuration / 2.0)
                let fadeOutStart = max(0.0, clipDuration - fadeDuration)
                let allowFadeForDuration = clipDuration >= 2.0
                let applyAudioFade = self.clipAudioOnlyAddFadeInOut && allowFadeForDuration
                let codec: String
                switch self.clipAudioOnlyFormat {
                case .mp3:
                    codec = "libmp3lame"
                case .m4a:
                    codec = "aac"
                case .wav:
                    codec = "pcm_s16le"
                }
                let sourceAsset = AVURLAsset(url: sourceURL)
                guard let selectedAudioTrackIndex = self.preferredAudioTrackIndex(for: sourceAsset) else {
                    await MainActor.run {
                        guard self.activeClipExportRunToken == exportRunToken else { return }
                        self.activeClipExportRunToken = nil
                        self.exportTask = nil
                        self.isExporting = false
                        self.exportProgress = 0
                        self.exportStatusText = "Clip export failed: No audio track found in source."
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    }
                    return
                }

                var audioFilters: [String] = []
                if applyAudioFade {
                    audioFilters.append("afade=t=in:st=0:d=\(String(format: "%.3f", fadeDuration))")
                    audioFilters.append("afade=t=out:st=\(String(format: "%.3f", fadeOutStart)):d=\(String(format: "%.3f", fadeDuration))")
                }
                if self.clipAudioOnlyBoostAudio {
                    audioFilters.append("volume=\(self.clipAdvancedBoostAmount.rawValue)dB")
                    audioFilters.append("alimiter=limit=0.988553")
                }

                var args = [
                    "-y",
                    "-hide_banner",
                    "-loglevel", "error",
                    "-ss", start,
                    "-t", durationStr,
                    "-i", sourceURL.path,
                    "-vn"
                ]

                let audioInputRef = "0:a:\(selectedAudioTrackIndex)"
                if !audioFilters.isEmpty {
                    args.append(contentsOf: [
                        "-filter_complex", "[\(audioInputRef)]\(audioFilters.joined(separator: ","))[aout]",
                        "-map", "[aout]"
                    ])
                } else {
                    args.append(contentsOf: ["-map", audioInputRef])
                }

                var outputArgs = [
                    "-c:a", codec
                ]
                if self.clipAudioOnlyFormat != .wav {
                    outputArgs.append(contentsOf: ["-b:a", "\(bitrateKbps)k"])
                }

                let encodeError = await self.runFFmpegProcessWithProgress(
                    executableURL: ffmpegURL,
                    arguments: args + outputArgs + [destination.path],
                    durationSeconds: clipDuration,
                    statusPrefix: "Exporting audio-only clip"
                )

                await MainActor.run {
                    guard self.activeClipExportRunToken == exportRunToken else { return }
                    self.activeClipExportRunToken = nil
                    self.exportTask = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    if self.exportCancellationRequested {
                        self.exportStatusText = "Clip export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                        self.notifyCompletion("Audio-Only Clip Export Stopped", message: self.exportStatusText)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                        return
                    }
                    if let encodeError {
                        self.exportStatusText = "Clip export failed: \(encodeError)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.notifyCompletion("Audio-Only Clip Export Failed", message: self.exportStatusText)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    } else {
                        self.outputURL = destination
                        self.exportStatusText = "Clip export complete: \(destination.lastPathComponent)"
                        if self.clipAudioOnlyAddFadeInOut && !applyAudioFade {
                            self.uiMessage = "Clip export complete: \(destination.lastPathComponent). Audio fade was skipped for clips under 2.0s."
                        } else {
                            self.uiMessage = self.exportStatusText
                        }
                        self.lastActivityState = .success
                        self.notifyCompletion("Audio-Only Clip Export Complete", message: self.uiMessage)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.exportStatusText, outputURL: destination)
                    }
                }
            }
            return
        }

        if clipEncodingMode == .fast {
            guard selectedClipFormat.supportsPassthrough else {
                activeClipExportRunToken = nil
                isExporting = false
                exportStatusText = "Fast mode supports only MP4 and MOV."
                uiMessage = exportStatusText
                lastActivityState = .failed
                finalizeQueued(.failed, exportStatusText)
                return
            }
            let asset = AVURLAsset(url: sourceURL)
            let preset = AVAssetExportPresetPassthrough

            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                activeClipExportRunToken = nil
                isExporting = false
                exportStatusText = "Clip export failed: Unable to create passthrough export session"
                uiMessage = exportStatusText
                lastActivityState = .failed
                finalizeQueued(.failed, exportStatusText)
                return
            }
            activeExportSession = session

            session.outputURL = destination
            session.outputFileType = selectedClipFormat.fileType
            session.shouldOptimizeForNetworkUse = true
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: clipStartSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: clipDurationSeconds, preferredTimescale: 600)
            )

            exportTask = Task { [weak self] in
                guard let self else { return }

                let monitor = Task { [weak self] in
                    while session.status == .waiting || session.status == .exporting {
                        await MainActor.run {
                            self?.exportProgress = Double(session.progress)
                            self?.exportStatusText = "Exporting clip… \(Int((Double(session.progress) * 100).rounded()))%"
                        }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }

                await withCheckedContinuation { continuation in
                    session.exportAsynchronously {
                        continuation.resume()
                    }
                }
                monitor.cancel()

                await MainActor.run {
                    guard self.activeClipExportRunToken == exportRunToken else { return }
                    self.activeClipExportRunToken = nil
                    self.exportTask = nil
                    self.activeExportSession = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    if self.exportCancellationRequested {
                        self.exportStatusText = "Clip export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                        self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                        return
                    }
                    switch session.status {
                    case .completed:
                        self.outputURL = destination
                        self.exportStatusText = "Clip export complete: \(destination.lastPathComponent)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .success
                        self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.exportStatusText, outputURL: destination)
                    case .failed:
                        self.exportStatusText = "Clip export failed: \(session.error?.localizedDescription ?? "Unknown error")"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    case .cancelled:
                        self.exportStatusText = "Clip export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                        self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                    default:
                        self.exportStatusText = "Clip export ended with status: \(session.status.rawValue)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    }
                }
            }
            return
        }

        exportTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.exportProgress = 0.1
                self.exportStatusText = "Encoding compressed clip…"
            }

            guard let ffmpegURL = self.findFFmpegExecutable() else {
                await MainActor.run {
                    guard self.activeClipExportRunToken == exportRunToken else { return }
                    self.activeClipExportRunToken = nil
                    self.exportTask = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    self.exportStatusText = "Clip export failed: No ffmpeg executable found."
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                    self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                }
                return
            }

            let bitrateKbps = max(500, Int((self.clipVideoBitrateMbps * 1000.0).rounded()))
            let audioBitrateKbps = min(max(64, self.clipAudioBitrateKbps), 320)
            // CRITICAL REGRESSION GUARD:
            // DO NOT REORDER THIS SEEK SEQUENCE.
            // Keep this hybrid seek order for advanced ffmpeg exports:
            //   -ss <coarse pre-roll> -i <source> -ss <fine offset> -t <duration>
            // Using only post-input seek here has repeatedly reintroduced a black
            // first frame on long-GOP sources in both captioned and non-captioned paths.
            // Any caption path must reuse this exact order as well.
            let decoderPreRollSeconds = 2.5
            let coarseSeekSeconds = max(0.0, self.clipStartSeconds - decoderPreRollSeconds)
            let fineSeekSeconds = max(0.0, self.clipStartSeconds - coarseSeekSeconds)
            let coarseSeek = String(format: "%.6f", coarseSeekSeconds)
            let fineSeek = String(format: "%.6f", fineSeekSeconds)
            let clipDuration = max(0.001, self.clipEndSeconds - self.clipStartSeconds)
            let durationStr = String(format: "%.3f", clipDuration)
            let fadeDuration = min(0.333, clipDuration / 2.0)
            let fadeOutStart = max(0.0, clipDuration - fadeDuration)
            let allowFadeForDuration = clipDuration >= 2.0
            let applyAudioFade = self.clipAdvancedAddFadeInOut && allowFadeForDuration
            let isWebM = self.selectedClipFormat == .webm
            let sourceAsset = AVURLAsset(url: sourceURL)
            let selectedAudioTrackIndex = self.preferredAudioTrackIndex(for: sourceAsset)
            let hasSourceAudio = (selectedAudioTrackIndex != nil)
            let videoCodec = isWebM ? "libvpx-vp9" : (self.clipAdvancedVideoCodec == .hevc ? "libx265" : "libx264")
            let audioCodec = isWebM ? "libopus" : "aac"
            var videoFilters: [String] = []
            var audioFilters: [String] = []
            // Baseline args for advanced export. For captioned exports we run this
            // exact baseline path to a temp clip first, then do a dedicated burn pass.
            var baselineArgs = [
                "-y",
                "-hide_banner",
                "-loglevel", "error",
                "-ss", coarseSeek,
                "-i", sourceURL.path,
                "-ss", fineSeek,
                "-t", durationStr,
                "-map", "0:v:0",
                "-c:v", videoCodec,
                "-preset", self.clipCompatibleSpeedPreset.ffmpegPreset,
                "-pix_fmt", "yuv420p",
                "-b:v", "\(bitrateKbps)k"
            ]

            if let scaleFilter = self.clipCompatibleMaxResolution.scaleFilter {
                videoFilters.append(scaleFilter)
            }

            if applyAudioFade && hasSourceAudio {
                audioFilters.append("afade=t=in:st=0:d=\(String(format: "%.3f", fadeDuration))")
                audioFilters.append("afade=t=out:st=\(String(format: "%.3f", fadeOutStart)):d=\(String(format: "%.3f", fadeDuration))")
            }

            if self.clipAdvancedBoostAudio && hasSourceAudio {
                audioFilters.append("volume=\(self.clipAdvancedBoostAmount.rawValue)dB")
                audioFilters.append("alimiter=limit=0.988553")
            }

            if let selectedAudioTrackIndex {
                let audioInputRef = "0:a:\(selectedAudioTrackIndex)"
                if !audioFilters.isEmpty {
                    baselineArgs.append(contentsOf: [
                        "-filter_complex", "[\(audioInputRef)]\(audioFilters.joined(separator: ","))[aout]",
                        "-map", "[aout]"
                    ])
                } else {
                    baselineArgs.append(contentsOf: ["-map", audioInputRef])
                }
                baselineArgs.append(contentsOf: [
                    "-c:a", audioCodec,
                    "-b:a", "\(audioBitrateKbps)k"
                ])
            }

            if self.selectedClipFormat == .mp4 || self.selectedClipFormat == .mov {
                baselineArgs.append(contentsOf: ["-movflags", "+faststart"])
            }

            var encodeError: String? = nil
            if self.clipAdvancedBurnInCaptions {
                // CAPTION PIPELINE REGRESSION GUARD:
                // Keep captioned exports as a strict staged-base 2-step flow:
                //   1) Create a staged base clip using the same hybrid seek order as advanced export
                //      (-ss coarse -> -i source -> -ss fine -> -t duration).
                //   2) Generate captions from staged base audio and burn onto that same staged base video.
                //
                // This prevents:
                // - recurring black-first-frame regressions from seek-order drift, and
                // - fixed subtitle lead/lag offsets from mixed time origins.
                //
                // Do NOT collapse caption exports into a direct source->burn single pass
                // unless both black-frame behavior and sync are re-validated on long-GOP/VFR sources.
                await MainActor.run {
                    self.exportProgress = max(self.exportProgress, 0.12)
                    self.exportStatusText = "Generating captions…"
                }
                let captionStageDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bvt-caption-stage-\(UUID().uuidString)", isDirectory: true)
                var captionStageReady = true
                do {
                    try FileManager.default.createDirectory(at: captionStageDirectory, withIntermediateDirectories: true)
                } catch {
                    captionStageReady = false
                    encodeError = "Unable to create temporary caption stage directory: \(error.localizedDescription)"
                }
                defer {
                    try? FileManager.default.removeItem(at: captionStageDirectory)
                }

                if captionStageReady {
                    let stagedBaseURL = captionStageDirectory.appendingPathComponent("base.\(self.selectedClipFormat.fileExtension)")
                    var stageArgs = baselineArgs
                    if !videoFilters.isEmpty {
                        stageArgs.append(contentsOf: ["-vf", videoFilters.joined(separator: ",")])
                    }
                    stageArgs.append(stagedBaseURL.path)

                    let stageError = await self.runFFmpegProcessWithProgress(
                        executableURL: ffmpegURL,
                        arguments: stageArgs,
                        durationSeconds: clipDuration,
                        statusPrefix: "Preparing base clip",
                        progressRange: 0.10...0.50
                    )

                    if self.exportCancellationRequested {
                        encodeError = nil
                    } else if let stageError {
                        encodeError = stageError
                    } else {
                        let captionPrep = await self.prepareWhisperBurnInCaptions(
                            sourceURL: stagedBaseURL,
                            ffmpegURL: ffmpegURL,
                            coarseSeekSeconds: 0.0,
                            fineSeekSeconds: 0.0,
                            durationSeconds: clipDuration
                        )

                        if self.exportCancellationRequested {
                            encodeError = nil
                        } else if let prepared = captionPrep.preparation {
                            defer {
                                try? FileManager.default.removeItem(at: prepared.tempDirectory)
                            }

                            let cueCount = self.countSRTCues(at: prepared.srtURL)
                            if cueCount <= 0 {
                                encodeError = "Caption generation produced 0 cues. SRT: \(prepared.srtURL.path)"
                            } else {
                                await MainActor.run {
                                    self.exportStatusText = "Encoding captioned clip… (\(cueCount) cues)"
                                }

                                var burnArgs = [
                                    "-y",
                                    "-hide_banner",
                                    "-loglevel", "error",
                                    "-i", stagedBaseURL.path,
                                    "-map", "0:v:0",
                                    "-c:v", videoCodec,
                                    "-preset", self.clipCompatibleSpeedPreset.ffmpegPreset,
                                    "-pix_fmt", "yuv420p",
                                    "-b:v", "\(bitrateKbps)k",
                                    "-vf", self.subtitlesFilterArgument(path: prepared.srtURL.path, style: self.clipAdvancedCaptionStyle),
                                    "-map", "0:a:0?",
                                    "-c:a", "copy"
                                ]
                                if self.selectedClipFormat == .mp4 || self.selectedClipFormat == .mov {
                                    burnArgs.append(contentsOf: ["-movflags", "+faststart"])
                                }
                                burnArgs.append(destination.path)

                                encodeError = await self.runFFmpegProcessWithProgress(
                                    executableURL: ffmpegURL,
                                    arguments: burnArgs,
                                    durationSeconds: clipDuration,
                                    statusPrefix: "Encoding captioned clip",
                                    progressRange: 0.55...1.0
                                )
                            }
                        } else {
                            encodeError = captionPrep.error ?? "Unknown caption generation failure."
                        }
                    }
                }
            } else {
                var args = baselineArgs
                if !videoFilters.isEmpty {
                    args.append(contentsOf: ["-vf", videoFilters.joined(separator: ",")])
                }
                args.append(destination.path)
                encodeError = await self.runFFmpegProcessWithProgress(
                    executableURL: ffmpegURL,
                    arguments: args,
                    durationSeconds: clipDuration,
                    statusPrefix: "Encoding advanced clip"
                )
            }

            await MainActor.run {
                guard self.activeClipExportRunToken == exportRunToken else { return }
                self.activeClipExportRunToken = nil
                self.exportTask = nil
                self.isExporting = false
                self.exportProgress = 0
                if self.exportCancellationRequested {
                    self.exportStatusText = "Clip export cancelled"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .cancelled
                    self.notifyCompletion("Compatible Clip Export Stopped", message: self.exportStatusText)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                    return
                }
                if let encodeError {
                    self.exportStatusText = "Clip export failed: \(encodeError)"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                    self.notifyCompletion("Compatible Clip Export Failed", message: self.exportStatusText)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                } else {
                    self.outputURL = destination
                    self.exportStatusText = "Clip export complete: \(destination.lastPathComponent)"
                    if self.clipAdvancedAddFadeInOut && !applyAudioFade {
                        self.uiMessage = "Clip export complete: \(destination.lastPathComponent). Audio fade was skipped for clips under 2.0s."
                    } else {
                        self.uiMessage = self.exportStatusText
                    }
                    self.lastActivityState = .success
                    self.notifyCompletion("Compatible Clip Export Complete", message: self.uiMessage)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.exportStatusText, outputURL: destination)
                }
            }
        }
    }

    private struct BurnInCaptionPreparation {
        let srtURL: URL
        let tempDirectory: URL
    }

    private func escapeSubtitlesFilterPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: ",", with: "\\,")
    }

    private func subtitlesFilterArgument(path: String, style: BurnInCaptionStyle) -> String {
        let escapedPath = escapeSubtitlesFilterPath(path)
        let escapedStyle = style.ffmpegForceStyle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "subtitles='\(escapedPath)':force_style='\(escapedStyle)'"
    }

    private func prepareWhisperBurnInCaptions(
        sourceURL: URL,
        ffmpegURL: URL,
        coarseSeekSeconds: Double,
        fineSeekSeconds: Double,
        durationSeconds: Double
    ) async -> (preparation: BurnInCaptionPreparation?, error: String?) {
        guard let whisperURL = findWhisperExecutable(),
              let whisperModelURL = findWhisperModel() else {
            return (nil, "Whisper resources are not bundled. Rebuild the app with bundled whisper-cli and model.")
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bvt-burnin-captions-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        } catch {
            return (nil, "Unable to create temporary caption directory: \(error.localizedDescription)")
        }

        let wavURL = tempDirectory.appendingPathComponent("caption-audio.wav")
        let outputPrefix = tempDirectory.appendingPathComponent("caption-track")
        let srtURL = tempDirectory.appendingPathComponent("caption-track.srt")
        // Keep caption-audio extraction time-origin identical to advanced clip export:
        // -ss <coarse pre-roll> -i <source> -ss <fine offset> -t <duration>
        // This prevents fixed subtitle offsets (captions consistently early/late).
        let coarseSeek = String(format: "%.6f", max(0.0, coarseSeekSeconds))
        let fineSeek = String(format: "%.6f", max(0.0, fineSeekSeconds))
        let duration = String(format: "%.3f", max(0.001, durationSeconds))

        let extractError = await runFFmpegProcessWithProgress(
            executableURL: ffmpegURL,
            arguments: [
                "-y",
                "-hide_banner",
                "-loglevel", "error",
                "-ss", coarseSeek,
                "-i", sourceURL.path,
                "-ss", fineSeek,
                "-t", duration,
                "-vn",
                "-ac", "1",
                "-ar", "16000",
                "-f", "wav",
                wavURL.path
            ]
            ,
            durationSeconds: max(0.001, durationSeconds),
            statusPrefix: "Generating captions",
            progressRange: 0.10...0.35
        )
        if exportCancellationRequested {
            return (nil, "Cancelled")
        }
        if let extractError {
            return (nil, "Caption audio extraction failed: \(extractError)")
        }

        let whisperArgs = [
            "-m", whisperModelURL.path,
            "-f", wavURL.path,
            "-of", outputPrefix.path,
            "-osrt",
            "-pp"
        ]
        let whisperError = await runWhisperProcessWithProgress(
            executableURL: whisperURL,
            arguments: whisperArgs,
            statusPrefix: "Generating captions",
            progressRange: 0.35...0.55
        )
        if exportCancellationRequested {
            return (nil, "Cancelled")
        }

        if whisperError != nil {
            // Retry with CPU-safe flags; some runtime combinations fail on first accelerated attempt.
            let retryError = await runWhisperProcessWithProgress(
                executableURL: whisperURL,
                arguments: [
                    "-ng",
                    "-nfa"
                ] + whisperArgs,
                statusPrefix: "Generating captions",
                progressRange: 0.35...0.55
            )
            if exportCancellationRequested {
                return (nil, "Cancelled")
            }
            if let retryError {
                return (nil, "Whisper transcription failed: \(retryError)")
            }
        }

        guard FileManager.default.fileExists(atPath: srtURL.path) else {
            return (nil, "Whisper did not produce subtitle output.")
        }

        do {
            let rawSRT = try String(contentsOf: srtURL, encoding: .utf8)
            let cueCount = rawSRT.components(separatedBy: .newlines).filter { $0.contains("-->") }.count
            guard cueCount > 0 else {
                return (nil, "Whisper produced subtitle file with 0 cues.")
            }
        } catch {
            return (nil, "Unable to validate subtitle file: \(error.localizedDescription)")
        }

        return (BurnInCaptionPreparation(srtURL: srtURL, tempDirectory: tempDirectory), nil)
    }

    private func countSRTCues(at url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: .newlines).filter { $0.contains("-->") }.count
    }

    private func shellQuoted(_ argument: String) -> String {
        if argument.isEmpty { return "\"\"" }
        let requiresQuote = argument.contains { $0.isWhitespace || $0 == "\"" || $0 == "'" }
        if !requiresQuote { return argument }
        return "\"" + argument.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func formatProcessCommand(executableURL: URL, arguments: [String]) -> String {
        ([executableURL.path] + arguments).map(shellQuoted).joined(separator: " ")
    }

    private func runProcess(executableURL: URL, arguments: [String]) async -> String? {
        let commandLine = formatProcessCommand(executableURL: executableURL, arguments: arguments)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout

            Task { @MainActor [weak self] in
                self?.appendActivityConsole("$ \(commandLine)", source: executableURL.lastPathComponent)
            }

            let streamToConsole: (Data, String) -> Void = { data, source in
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    Task { @MainActor [weak self] in
                        self?.appendActivityConsole(line, source: source)
                    }
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                streamToConsole(handle.availableData, "stdout")
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                streamToConsole(handle.availableData, "stderr")
            }

            do {
                try process.run()
                Task { @MainActor in
                    self.activeProcess = process
                }
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: error.localizedDescription)
                return
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    if self.activeProcess === proc {
                        self.activeProcess = nil
                    }
                }
                let trailingStdout = stdout.fileHandleForReading.readDataToEndOfFile()
                let trailingStderr = stderr.fileHandleForReading.readDataToEndOfFile()
                streamToConsole(trailingStdout, "stdout")
                streamToConsole(trailingStderr, "stderr")

                let errorText = String(decoding: trailingStderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else if errorText.isEmpty {
                    continuation.resume(returning: "\(executableURL.lastPathComponent) exited with status \(proc.terminationStatus)")
                } else {
                    continuation.resume(returning: errorText)
                }
            }
        }
    }

    private func runWhisperProcessWithProgress(
        executableURL: URL,
        arguments: [String],
        statusPrefix: String,
        progressRange: ClosedRange<Double>
    ) async -> String? {
        let commandLine = formatProcessCommand(executableURL: executableURL, arguments: arguments)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout

            Task { @MainActor [weak self] in
                self?.appendActivityConsole("$ \(commandLine)", source: "whisper")
            }

            func emitProgress(_ progress: Double) {
                Task { @MainActor in
                    guard self.isExporting else { return }
                    let clamped = min(max(progress, 0), 1)
                    let mapped = progressRange.lowerBound + ((progressRange.upperBound - progressRange.lowerBound) * clamped)
                    self.exportProgress = min(max(mapped, 0), 1)
                    self.exportStatusText = "\(statusPrefix)… \(Int((clamped * 100).rounded()))%"
                }
            }

            let parseChunk: (Data, String) -> Void = { data, source in
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    Task { @MainActor [weak self] in
                        self?.appendActivityConsole(line, source: source)
                    }
                    if let progress = extractPercentProgress(from: line) {
                        emitProgress(progress)
                    }
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                parseChunk(handle.availableData, "whisper")
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                parseChunk(handle.availableData, "whisper")
            }

            do {
                try process.run()
                Task { @MainActor in
                    self.activeProcess = process
                }
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: error.localizedDescription)
                return
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    if self.activeProcess === proc {
                        self.activeProcess = nil
                    }
                }

                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                parseChunk(stdoutData, "whisper")
                parseChunk(stderrData, "whisper")

                let stderrText = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 {
                    emitProgress(1.0)
                    continuation.resume(returning: nil)
                } else if stderrText.isEmpty {
                    continuation.resume(returning: "\(executableURL.lastPathComponent) exited with status \(proc.terminationStatus)")
                } else {
                    continuation.resume(returning: stderrText)
                }
            }
        }
    }

    private func runFFmpegProcessWithProgress(
        executableURL: URL,
        arguments: [String],
        durationSeconds: Double,
        statusPrefix: String,
        progressRange: ClosedRange<Double>? = nil
    ) async -> String? {
        let ffmpegArguments = arguments + ["-progress", "pipe:1", "-nostats"]
        let commandLine = formatProcessCommand(executableURL: executableURL, arguments: ffmpegArguments)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ffmpegArguments

            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout

            let safeDuration = max(0.001, durationSeconds)
            var stdoutBuffer = Data()
            var stderrBuffer = Data()
            var stderrLines: [String] = []

            Task { @MainActor [weak self] in
                self?.appendActivityConsole("$ \(commandLine)", source: "ffmpeg")
            }

            let emitProgress: (_ progress: Double, _ allowComplete: Bool) -> Void = { [weak self] progress, allowComplete in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isExporting else { return }
                    let clamped = min(max(progress, 0), 1)
                    let visualProgress = allowComplete ? clamped : min(clamped, 0.99)
                    if let range = progressRange {
                        let mapped = range.lowerBound + ((range.upperBound - range.lowerBound) * visualProgress)
                        self.exportProgress = min(max(mapped, 0), 1)
                    } else {
                        self.exportProgress = visualProgress
                    }
                    self.exportStatusText = "\(statusPrefix)… \(Int((visualProgress * 100).rounded()))%"
                }
            }

            let emitConsoleLine: (String, String) -> Void = { line, source in
                Task { @MainActor [weak self] in
                    self?.appendActivityConsole(line, source: source)
                }
            }

            func consumeLines(buffer: inout Data, source: String, processLine: (String) -> Void) {
                while let separatorIndex = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineData = buffer.subdata(in: 0..<separatorIndex)
                    buffer.removeSubrange(0...separatorIndex)
                    guard let line = String(data: lineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          !line.isEmpty else { continue }
                    emitConsoleLine(line, source)
                    processLine(line)
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stdoutBuffer.append(chunk)
                consumeLines(buffer: &stdoutBuffer, source: "ffmpeg") { rawLine in
                    if rawLine == "progress=end" {
                        emitProgress(1.0, true)
                        return
                    }

                    if rawLine.hasPrefix("out_time_us="),
                       let microseconds = Double(rawLine.dropFirst("out_time_us=".count)) {
                        emitProgress((microseconds / 1_000_000.0) / safeDuration, false)
                        return
                    }

                    if rawLine.hasPrefix("out_time_ms="),
                       let value = Double(rawLine.dropFirst("out_time_ms=".count)) {
                        // ffmpeg emits this value in microseconds.
                        emitProgress((value / 1_000_000.0) / safeDuration, false)
                        return
                    }

                    if rawLine.hasPrefix("out_time="),
                       let seconds = parseTimecode(String(rawLine.dropFirst("out_time=".count))) {
                        emitProgress(seconds / safeDuration, false)
                    }
                }
            }

            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stderrBuffer.append(chunk)
                consumeLines(buffer: &stderrBuffer, source: "ffmpeg") { rawLine in
                    stderrLines.append(rawLine)
                }
            }

            do {
                try process.run()
                Task { @MainActor in
                    self.activeProcess = process
                }
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: error.localizedDescription)
                return
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    if self.activeProcess === proc {
                        self.activeProcess = nil
                    }
                }

                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                let trailingStdout = stdout.fileHandleForReading.readDataToEndOfFile()
                if !trailingStdout.isEmpty {
                    stdoutBuffer.append(trailingStdout)
                }
                if !stderrData.isEmpty {
                    stderrBuffer.append(stderrData)
                }

                consumeLines(buffer: &stdoutBuffer, source: "ffmpeg") { rawLine in
                    if rawLine == "progress=end" {
                        emitProgress(1.0, true)
                        return
                    }

                    if rawLine.hasPrefix("out_time_us="),
                       let microseconds = Double(rawLine.dropFirst("out_time_us=".count)) {
                        emitProgress((microseconds / 1_000_000.0) / safeDuration, false)
                        return
                    }

                    if rawLine.hasPrefix("out_time_ms="),
                       let value = Double(rawLine.dropFirst("out_time_ms=".count)) {
                        emitProgress((value / 1_000_000.0) / safeDuration, false)
                        return
                    }

                    if rawLine.hasPrefix("out_time="),
                       let seconds = parseTimecode(String(rawLine.dropFirst("out_time=".count))) {
                        emitProgress(seconds / safeDuration, false)
                    }
                }
                consumeLines(buffer: &stderrBuffer, source: "ffmpeg") { rawLine in
                    stderrLines.append(rawLine)
                }

                let stderrText = String(decoding: stderrData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stdoutText = String(decoding: stdoutBuffer, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stderrFromLines = stderrLines.suffix(8).joined(separator: "\n")

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else if !stderrText.isEmpty {
                    continuation.resume(returning: stderrText)
                } else if !stderrFromLines.isEmpty {
                    continuation.resume(returning: stderrFromLines)
                } else if !stdoutText.isEmpty {
                    continuation.resume(returning: stdoutText)
                } else {
                    continuation.resume(returning: "\(executableURL.lastPathComponent) exited with status \(proc.terminationStatus)")
                }
            }
        }
    }

    private func runYTDLPProcessWithProgress(
        executableURL: URL,
        preArguments: [String],
        arguments: [String],
        statusPrefix: String,
        progressRange: ClosedRange<Double>
    ) async -> (downloadedPath: String?, error: String?) {
        let finalArguments = preArguments + arguments
        let commandLine = formatProcessCommand(executableURL: executableURL, arguments: finalArguments)
        return await withCheckedContinuation { (continuation: CheckedContinuation<(downloadedPath: String?, error: String?), Never>) in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = finalArguments

            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout

            var stdoutBuffer = Data()
            var stderrBuffer = Data()
            var stderrLines: [String] = []
            var outputPath: String?

            func isYTDLPWarningLine(_ line: String) -> Bool {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let upper = trimmed.uppercased()
                return upper.hasPrefix("WARNING:") || upper.hasPrefix("[WARNING]")
            }

            Task { @MainActor [weak self] in
                self?.appendActivityConsole("$ \(commandLine)", source: "yt-dlp")
            }

            let emitProgress: (Double) -> Void = { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isExporting else { return }
                    let clamped = min(max(progress, 0), 1)
                    let mapped = progressRange.lowerBound + ((progressRange.upperBound - progressRange.lowerBound) * clamped)
                    self.exportProgress = min(max(mapped, 0), 1)
                    self.exportStatusText = "\(statusPrefix)… \(Int((clamped * 100).rounded()))%"
                }
            }

            let emitConsoleLine: (String, String) -> Void = { line, source in
                Task { @MainActor [weak self] in
                    self?.appendActivityConsole(line, source: source)
                }
            }

            let parseLine: (String) -> Void = { rawLine in
                if let progress = extractPercentProgress(from: rawLine) {
                    emitProgress(progress)
                }

                if rawLine.hasPrefix("after_move:") {
                    let path = String(rawLine.dropFirst("after_move:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty {
                        outputPath = path
                    }
                } else if rawLine.hasPrefix("/") {
                    let path = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if FileManager.default.fileExists(atPath: path) {
                        outputPath = path
                    }
                }
            }

            func consumeLines(buffer: inout Data, source: String) {
                while let separatorIndex = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineData = buffer.subdata(in: 0..<separatorIndex)
                    buffer.removeSubrange(0...separatorIndex)
                    guard let line = String(data: lineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          !line.isEmpty else { continue }
                    emitConsoleLine(line, source)
                    parseLine(line)
                    if source == "stderr" {
                        stderrLines.append(line)
                    }
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stdoutBuffer.append(chunk)
                consumeLines(buffer: &stdoutBuffer, source: "yt-dlp")
            }

            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stderrBuffer.append(chunk)
                consumeLines(buffer: &stderrBuffer, source: "stderr")
            }

            do {
                try process.run()
                Task { @MainActor in
                    self.activeProcess = process
                }
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (nil, error.localizedDescription))
                return
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    if self.activeProcess === proc {
                        self.activeProcess = nil
                    }
                }

                let trailingStdout = stdout.fileHandleForReading.readDataToEndOfFile()
                let trailingStderr = stderr.fileHandleForReading.readDataToEndOfFile()
                if !trailingStdout.isEmpty { stdoutBuffer.append(trailingStdout) }
                if !trailingStderr.isEmpty { stderrBuffer.append(trailingStderr) }
                consumeLines(buffer: &stdoutBuffer, source: "yt-dlp")
                consumeLines(buffer: &stderrBuffer, source: "stderr")

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: (outputPath, nil))
                } else {
                    let nonWarningLines = stderrLines.filter { !isYTDLPWarningLine($0) }

                    // Some sites (for example TikTok) can emit impersonation warnings while still
                    // producing a valid output file. Don't fail on warning-only stderr in that case.
                    if nonWarningLines.isEmpty,
                       let outputPath,
                       FileManager.default.fileExists(atPath: outputPath) {
                        continuation.resume(returning: (outputPath, nil))
                        return
                    }

                    let stderrText = nonWarningLines.suffix(8).joined(separator: "\n")
                    if stderrText.isEmpty {
                        continuation.resume(returning: (nil, "yt-dlp exited with status \(proc.terminationStatus)"))
                    } else {
                        continuation.resume(returning: (nil, stderrText))
                    }
                }
            }
        }
    }

    private func findFFmpegExecutable() -> URL? {
        if let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        var candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for entry in path.split(separator: ":") {
                candidates.append(String(entry) + "/ffmpeg")
            }
        }

        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private func findFFprobeExecutable() -> URL? {
        if let bundled = Bundle.main.url(forResource: "ffprobe", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        var candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for entry in path.split(separator: ":") {
                candidates.append(String(entry) + "/ffprobe")
            }
        }

        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private func findYTDLPExecutable() -> URL? {
        if let bundled = Bundle.main.url(forResource: "yt-dlp", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let candidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for entry in path.split(separator: ":") {
                let candidate = String(entry) + "/yt-dlp"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }

        return nil
    }

    private struct YTDLPLaunchCommand {
        let executableURL: URL
        let preArguments: [String]
    }

    private func resolveYTDLPLaunch() -> YTDLPLaunchCommand? {
        guard let ytDLPURL = findYTDLPExecutable() else { return nil }
        if isMachOExecutable(at: ytDLPURL) {
            return YTDLPLaunchCommand(executableURL: ytDLPURL, preArguments: [])
        }
        guard let pythonURL = findPython3Executable() else { return nil }
        return YTDLPLaunchCommand(executableURL: pythonURL, preArguments: [ytDLPURL.path])
    }

    private func findPython3Executable() -> URL? {
        var candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for entry in path.split(separator: ":") {
                let candidate = String(entry) + "/python3"
                if !candidates.contains(candidate) {
                    candidates.append(candidate)
                }
            }
        }
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private func isMachOExecutable(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 4), bytes.count == 4 else { return false }
        let magic = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let known: Set<UInt32> = [
            0xFEEDFACE, 0xCEFAEDFE,
            0xFEEDFACF, 0xCFFAEDFE,
            0xCAFEBABE, 0xBEBAFECA,
            0xCAFEBABF, 0xBFBAFECA
        ]
        return known.contains(magic)
    }

    func revealOutput() {
        guard let outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
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

    func chooseCustomFrameSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a default folder for captured frames"
        panel.title = "Default Frame Save Location"
        if panel.runModal() == .OK, let url = panel.url {
            customFrameSaveDirectoryPath = url.path
        }
    }

    func captureFrame(at seconds: Double) {
        guard let sourceURL, hasVideoTrack else { return }

        let duration = sourceDurationSeconds
        let safeInput = seconds.isFinite ? seconds : 0
        let maxTime = duration > 0 ? max(0, duration - (1.0 / 600.0)) : safeInput
        let clampedTime = max(0, min(safeInput, maxTime))
        let defaultName = sourceURL.deletingPathExtension().lastPathComponent +
            "_frame_" + formatSeconds(clampedTime).replacingOccurrences(of: ":", with: "-") + ".png"

        let destinationURL: URL
        switch frameSaveLocationMode {
        case .askEachTime:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = defaultName
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            panel.title = "Save Frame"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destinationURL = url
        case .sourceFolder:
            let folder = sourceURL.deletingLastPathComponent()
            destinationURL = uniqueURL(in: folder, preferredFileName: defaultName)
        case .customFolder:
            let configuredFolder = URL(fileURLWithPath: customFrameSaveDirectoryPath)
            let folder: URL
            if !customFrameSaveDirectoryPath.isEmpty,
               FileManager.default.fileExists(atPath: configuredFolder.path) {
                folder = configuredFolder
            } else {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                panel.prompt = "Choose"
                panel.message = "Choose a default folder for captured frames"
                panel.title = "Default Frame Save Location"
                guard panel.runModal() == .OK, let picked = panel.url else { return }
                customFrameSaveDirectoryPath = picked.path
                folder = picked
            }
            destinationURL = uniqueURL(in: folder, preferredFileName: defaultName)
        }

        do {
            let asset = AVURLAsset(url: sourceURL)
            let captureTime = CMTime(seconds: clampedTime, preferredTimescale: 600)
            let cgImage: CGImage

            do {
                let strictGenerator = AVAssetImageGenerator(asset: asset)
                strictGenerator.appliesPreferredTrackTransform = true
                strictGenerator.requestedTimeToleranceBefore = CMTime(seconds: 1.0 / 120.0, preferredTimescale: 600)
                strictGenerator.requestedTimeToleranceAfter = CMTime(seconds: 1.0 / 120.0, preferredTimescale: 600)
                cgImage = try strictGenerator.copyCGImage(at: captureTime, actualTime: nil)
            } catch {
                // Fallback for files/timestamps where strict frame matching fails.
                let fallbackGenerator = AVAssetImageGenerator(asset: asset)
                fallbackGenerator.appliesPreferredTrackTransform = true
                fallbackGenerator.requestedTimeToleranceBefore = .positiveInfinity
                fallbackGenerator.requestedTimeToleranceAfter = .positiveInfinity
                cgImage = try fallbackGenerator.copyCGImage(at: captureTime, actualTime: nil)
            }

            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                uiMessage = "Frame capture failed: Unable to encode PNG."
                lastActivityState = .failed
                return
            }

            try pngData.write(to: destinationURL, options: .atomic)
            outputURL = destinationURL
            captureFrameFlashToken &+= 1
            uiMessage = "Frame saved: \(destinationURL.lastPathComponent)"
            lastActivityState = .success
            playFrameCaptureSound()
        } catch {
            let nsError = error as NSError
            uiMessage = "Frame capture failed (\(nsError.domain) \(nsError.code)): \(nsError.localizedDescription)"
            lastActivityState = .failed
        }
    }

    private func restoreMarkersWithUndo(
        _ markers: [CaptureTimelineMarker],
        highlightedID: UUID?,
        undoManager: UndoManager?,
        actionName: String
    ) {
        let currentMarkers = captureTimelineMarkers
        let currentHighlightedID = highlightedCaptureTimelineMarkerID
        captureTimelineMarkers = markers
        highlightedCaptureTimelineMarkerID = highlightedID
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreMarkersWithUndo(
                currentMarkers,
                highlightedID: currentHighlightedID,
                undoManager: undoManager,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
    }

    func addTimelineMarker(at seconds: Double, undoManager: UndoManager? = nil) {
        let previousMarkers = captureTimelineMarkers
        let previousHighlighted = highlightedCaptureTimelineMarkerID
        addCaptureTimelineMarker(at: seconds)
        let didChange = previousMarkers != captureTimelineMarkers
        if didChange {
            uiMessage = "Marker added at \(formatSeconds(seconds))"
            if let undoManager {
                undoManager.registerUndo(withTarget: self) { target in
                    target.restoreMarkersWithUndo(
                        previousMarkers,
                        highlightedID: previousHighlighted,
                        undoManager: undoManager,
                        actionName: "Add Marker"
                    )
                }
                undoManager.setActionName("Add Marker")
            }
        }
    }

    func nearestTimelineMarker(to seconds: Double, tolerance: Double) -> CaptureTimelineMarker? {
        guard tolerance >= 0 else { return nil }
        var nearest: CaptureTimelineMarker?
        var nearestDistance = Double.greatestFiniteMagnitude
        for marker in captureTimelineMarkers {
            let distance = abs(marker.seconds - seconds)
            guard distance <= tolerance, distance < nearestDistance else { continue }
            nearest = marker
            nearestDistance = distance
        }
        return nearest
    }

    func selectTimelineMarkerIfAligned(near seconds: Double, tolerance: Double = 1.0 / 30.0) {
        let next = nearestTimelineMarker(to: seconds, tolerance: tolerance)?.id
        if highlightedCaptureTimelineMarkerID != next {
            highlightedCaptureTimelineMarkerID = next
        }
    }

    func removeHighlightedTimelineMarker(undoManager: UndoManager? = nil) -> Bool {
        let previousMarkers = captureTimelineMarkers
        let previousHighlighted = highlightedCaptureTimelineMarkerID
        guard let highlightedID = highlightedCaptureTimelineMarkerID,
              let index = captureTimelineMarkers.firstIndex(where: { $0.id == highlightedID }) else {
            return false
        }
        captureTimelineMarkers.remove(at: index)
        highlightedCaptureTimelineMarkerID = nil
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.restoreMarkersWithUndo(
                    previousMarkers,
                    highlightedID: previousHighlighted,
                    undoManager: undoManager,
                    actionName: "Delete Marker"
                )
            }
            undoManager.setActionName("Delete Marker")
        }
        return true
    }

    func highlightTimelineMarker(near seconds: Double, tolerance: Double = 1.0 / 120.0) {
        if let marker = captureTimelineMarkers.first(where: { abs($0.seconds - seconds) <= tolerance }) {
            highlightedCaptureTimelineMarkerID = marker.id
            highlightedClipBoundary = nil
            scheduleCaptureMarkerHighlightClear(markerID: marker.id)
        } else {
            highlightedCaptureTimelineMarkerID = nil
        }
    }

    func highlightBoundaryIfNeeded(
        near seconds: Double,
        clipStart: Double,
        clipEnd: Double,
        tolerance: Double = 1.0 / 120.0
    ) {
        if abs(seconds - clipStart) <= tolerance {
            highlightedCaptureTimelineMarkerID = nil
            highlightedClipBoundary = .start
            scheduleClipBoundaryHighlightClear(.start)
            return
        }

        if abs(seconds - clipEnd) <= tolerance {
            highlightedCaptureTimelineMarkerID = nil
            highlightedClipBoundary = .end
            scheduleClipBoundaryHighlightClear(.end)
            return
        }

        highlightedClipBoundary = nil
    }

    private func addCaptureTimelineMarker(at seconds: Double) {
        let clamped = max(0, min(seconds, max(sourceDurationSeconds, seconds)))

        if let existing = captureTimelineMarkers.first(where: { abs($0.seconds - clamped) < 0.001 }) {
            highlightedCaptureTimelineMarkerID = existing.id
            scheduleCaptureMarkerHighlightClear(markerID: existing.id)
            return
        }

        let marker = CaptureTimelineMarker(seconds: clamped)
        captureTimelineMarkers.append(marker)
        captureTimelineMarkers.sort { $0.seconds < $1.seconds }
        if captureTimelineMarkers.count > 300 {
            captureTimelineMarkers.removeFirst(captureTimelineMarkers.count - 300)
        }
        highlightedCaptureTimelineMarkerID = marker.id
        scheduleCaptureMarkerHighlightClear(markerID: marker.id)
    }

    private func scheduleCaptureMarkerHighlightClear(markerID: UUID) {
        captureMarkerHighlightClearTask?.cancel()
        captureMarkerHighlightClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard let self, self.highlightedCaptureTimelineMarkerID == markerID else { return }
            if let marker = self.captureTimelineMarkers.first(where: { $0.id == markerID }),
               abs(marker.seconds - self.clipPlayheadSeconds) <= (1.0 / 30.0) {
                // Keep marker selected while playhead remains on it.
                return
            }
            withAnimation(.easeOut(duration: 0.18)) {
                self.highlightedCaptureTimelineMarkerID = nil
            }
        }
    }

    private func scheduleClipBoundaryHighlightClear(_ boundary: ClipBoundaryHighlight) {
        clipBoundaryHighlightClearTask?.cancel()
        clipBoundaryHighlightClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard let self, self.highlightedClipBoundary == boundary else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                self.highlightedClipBoundary = nil
            }
        }
    }

    private func playFrameCaptureSound() {
        if let bundledURL = Bundle.main.url(forResource: "FrameShutter", withExtension: "aiff"),
           let bundledSound = NSSound(contentsOf: bundledURL, byReference: true) {
            bundledSound.play()
            return
        }

        let preferred: [NSSound.Name] = [
            NSSound.Name("Grab"),   // macOS screenshot/Grab-style shutter sound
            NSSound.Name("Glass"),  // fallback
            NSSound.Name("Funk")    // fallback
        ]
        for name in preferred {
            if let sound = NSSound(named: name) {
                sound.play()
                return
            }
        }
    }

    private func playQuickExportSnipSound() {
        if let bundledURL = Bundle.main.url(forResource: "QuickExportSnip", withExtension: "aiff"),
           let bundledSound = NSSound(contentsOf: bundledURL, byReference: true) {
            bundledSound.play()
            return
        }

        let preferred: [NSSound.Name] = [
            NSSound.Name("Pop"),
            NSSound.Name("Tink"),
            NSSound.Name("Glass")
        ]
        for name in preferred {
            if let sound = NSSound(named: name) {
                sound.play()
                return
            }
        }
    }

    private func uniqueURL(in directory: URL, preferredFileName: String) -> URL {
        let ext = (preferredFileName as NSString).pathExtension
        let baseName = (preferredFileName as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(preferredFileName)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(baseName)-\(index)" : "\(baseName)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(nextName)
            index += 1
        }
        return candidate
    }

    private func uniqueUnderscoreIndexedURL(in directory: URL, preferredFileName: String) -> URL {
        let ext = (preferredFileName as NSString).pathExtension
        let baseName = (preferredFileName as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(preferredFileName)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(baseName)_\(index)" : "\(baseName)_\(index).\(ext)"
            candidate = directory.appendingPathComponent(nextName)
            index += 1
        }
        return candidate
    }

    private func notifyCompletion(_ title: String, message: String) {
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
