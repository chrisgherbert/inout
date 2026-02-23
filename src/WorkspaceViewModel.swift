import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import UserNotifications
import Foundation

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
        static let estimatedSizeWarningThresholdGB = "prefs.estimatedSizeWarningThresholdGB"
        static let estimatedSizeDangerThresholdGB = "prefs.estimatedSizeDangerThresholdGB"
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
        didSet { updateDockProgressIndicator() }
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
        didSet { updateDockProgressIndicator() }
    }
    @Published var exportProgress = 0.0 {
        didSet { updateDockProgressIndicator() }
    }
    @Published var exportStatusText = "No export yet"
    @Published var outputURL: URL?
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

    private var analyzeTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var captureMarkerHighlightClearTask: Task<Void, Never>?
    private var clipBoundaryHighlightClearTask: Task<Void, Never>?
    private let cancelFlag = CancellationFlag()
    private var activeExportSession: AVAssetExportSession?
    private var activeProcess: Process?
    private var willTerminateObserver: NSObjectProtocol?
    private var exportCancellationRequested = false
    private var notificationAuthRequested = false
    private var originalModeDefaultBitrateMbps: Double = 4.0
    private var waveformCache: [String: [Double]] = [:]
    private var waveformCacheOrder: [String] = []
    private let maxWaveformCacheEntries = 6

    init() {
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopCurrentActivity()
        }

        loadPreferences()
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

        if let rawCaptionStyle = defaults.string(forKey: DefaultsKey.burnInCaptionStyle),
           let style = BurnInCaptionStyle(rawValue: rawCaptionStyle) {
            clipAdvancedCaptionStyle = style
        }
    }

    var canAnalyze: Bool {
        sourceURL != nil && !isAnalyzing && !isExporting && !isGeneratingTranscript && (effectiveAnalyzeBlackFrames || effectiveAnalyzeAudioSilence || effectiveAnalyzeProfanity)
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
        findWhisperExecutable() != nil && findWhisperModel() != nil
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
        outputURL = nil
        captureTimelineMarkers = []
        highlightedCaptureTimelineMarkerID = nil
        highlightedClipBoundary = nil
        clipPlayheadSeconds = 0
        uiMessage = "Ready"
        resetClipRange()
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

        isGeneratingTranscript = true
        isAnalyzing = true
        lastActivityState = .running
        wasCancelled = false
        analyzeProgress = 0
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
                    }
                )
            }.value

            await MainActor.run {
                self.applyTranscriptGenerationResult(result)
            }
        }
    }

    func exportTranscriptTXTFromInspect() {
        guard let sourceURL else { return }
        guard !transcriptSegments.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "_transcript.txt"
        panel.message = "Export transcript as text"
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let content = transcriptSegments
            .map { "\($0.formatted)" }
            .joined(separator: "\n")

        do {
            try content.write(to: destination, atomically: true, encoding: .utf8)
            outputURL = destination
            uiMessage = "Transcript exported to \(destination.lastPathComponent)"
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

    func resetClipRange() {
        let duration = max(0, sourceInfo?.durationSeconds ?? analysis?.mediaDuration ?? 0)
        clipStartSeconds = 0
        clipEndSeconds = duration
        clipStartText = formatSeconds(clipStartSeconds)
        clipEndText = formatSeconds(clipEndSeconds)
    }

    private func applySuggestedClipBitrateFromSource() {
        let step = 0.5
        let sliderMin = 2.0
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

        clipVideoBitrateMbps = min(20.0, max(2.0, suggested))
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
        let duration = sourceDurationSeconds
        clipStartSeconds = min(max(0, clipStartSeconds), duration)
        clipEndSeconds = min(max(0, clipEndSeconds), duration)
        if clipEndSeconds < clipStartSeconds {
            clipEndSeconds = clipStartSeconds
        }
        clipStartText = formatSeconds(clipStartSeconds)
        clipEndText = formatSeconds(clipEndSeconds)
    }

    func commitClipStartText() {
        guard let parsed = parseTimecode(clipStartText) else {
            clipStartText = formatSeconds(clipStartSeconds)
            return
        }
        clipStartSeconds = parsed
        clampClipRange()
    }

    func commitClipEndText() {
        guard let parsed = parseTimecode(clipEndText) else {
            clipEndText = formatSeconds(clipEndSeconds)
            return
        }
        clipEndSeconds = parsed
        clampClipRange()
    }

    func setClipStart(_ time: Double) {
        clipStartSeconds = time
        clampClipRange()
    }

    func setClipEnd(_ time: Double) {
        clipEndSeconds = time
        clampClipRange()
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

    func startAnalysis() {
        guard canAnalyze, let url = sourceURL else { return }

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
            return
        }

        isAnalyzing = true
        lastActivityState = .running
        wasCancelled = false
        analyzeProgress = 0
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
        case .failure(.cancelled):
            transcriptStatusText = "Transcript generation stopped."
            analyzeStatusText = transcriptStatusText
            uiMessage = transcriptStatusText
            lastActivityState = .cancelled
            notifyCompletion("Transcript Stopped", message: transcriptStatusText)
        case .failure(.failed(let reason)):
            transcriptStatusText = "Transcript failed: \(reason)"
            analyzeStatusText = "Transcript generation failed"
            uiMessage = transcriptStatusText
            lastActivityState = .failed
            notifyCompletion("Transcript Failed", message: transcriptStatusText)
        }

    }

    private func stopExport() {
        guard isExporting else { return }
        exportCancellationRequested = true
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
    }

    func startExport() {
        guard canExport, let sourceURL else { return }

        let panel = NSSavePanel()
        if selectedAudioFormat == .mp3 {
            panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + ".mp3"
            panel.allowedContentTypes = [.mp3]
        } else {
            panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + ".m4a"
            panel.allowedContentTypes = [.mpeg4Audio]
        }
        panel.canCreateDirectories = true
        panel.title = "Export Audio"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        lastActivityState = .running
        exportCancellationRequested = false
        exportProgress = 0
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
                        return
                    }

                    switch session.status {
                    case .completed:
                        self.outputURL = destination
                        self.exportStatusText = "Export complete: \(destination.lastPathComponent)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .success
                    case .failed:
                        self.exportStatusText = "Export failed: \(session.error?.localizedDescription ?? "Unknown error")"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                    case .cancelled:
                        self.exportStatusText = "Export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                    default:
                        self.exportStatusText = "Export ended with status: \(session.status.rawValue)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
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
                    return
                }
                if let mp3Error {
                    self.exportStatusText = "MP3 export failed: \(mp3Error)"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                    self.notifyCompletion("MP3 Export Failed", message: self.exportStatusText)
                } else {
                    self.outputURL = destination
                    self.exportStatusText = "Export complete: \(destination.lastPathComponent)"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .success
                    self.notifyCompletion("MP3 Export Complete", message: self.exportStatusText)
                }
            }
        }
    }

    func startClipExport(skipSaveDialog: Bool = false) {
        guard canExportClip, let sourceURL else { return }
        if !hasVideoTrack && clipEncodingMode != .audioOnly {
            clipEncodingMode = .audioOnly
        }

        clampClipRange()
        guard clipDurationSeconds > 0 else { return }

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

        let defaultName = URL(fileURLWithPath: defaultBaseName).deletingPathExtension().lastPathComponent + "." + outputExtension

        let destination: URL
        if skipSaveDialog {
            let sourceDirectory = sourceURL.deletingLastPathComponent()
            destination = uniqueUnderscoreIndexedURL(in: sourceDirectory, preferredFileName: defaultName)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = defaultName
            panel.allowedContentTypes = [clipEncodingMode == .audioOnly ? clipAudioOnlyFormat.contentType : selectedClipFormat.contentType]
            panel.canCreateDirectories = true
            panel.title = "Export Clip"

            guard panel.runModal() == .OK, let chosenDestination = panel.url else { return }
            destination = chosenDestination
            try? FileManager.default.removeItem(at: destination)
        }

        if skipSaveDialog {
            DispatchQueue.main.async { [weak self] in
                self?.quickExportFlashToken &+= 1
            }
            playQuickExportSnipSound()
        }

        isExporting = true
        lastActivityState = .running
        exportCancellationRequested = false
        exportProgress = 0
        exportStatusText = skipSaveDialog ? "Quick exporting clip…" : "Exporting clip…"
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
                        self.exportTask = nil
                        self.isExporting = false
                        self.exportProgress = 0
                        self.exportStatusText = "Clip export failed: No ffmpeg executable found."
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
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
                        self.exportTask = nil
                        self.isExporting = false
                        self.exportProgress = 0
                        self.exportStatusText = "Clip export failed: No audio track found in source."
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                    }
                    return
                }

                var audioFilters: [String] = []
                if applyAudioFade {
                    audioFilters.append("afade=t=in:st=0:d=\(String(format: "%.3f", fadeDuration))")
                    audioFilters.append("afade=t=out:st=\(String(format: "%.3f", fadeOutStart)):d=\(String(format: "%.3f", fadeDuration))")
                }
                if self.clipAudioOnlyBoostAudio {
                    audioFilters.append("volume=10dB")
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
                    self.exportTask = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    if self.exportCancellationRequested {
                        self.exportStatusText = "Clip export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                        self.notifyCompletion("Audio-Only Clip Export Stopped", message: self.exportStatusText)
                        return
                    }
                    if let encodeError {
                        self.exportStatusText = "Clip export failed: \(encodeError)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.notifyCompletion("Audio-Only Clip Export Failed", message: self.exportStatusText)
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
                    }
                }
            }
            return
        }

        if clipEncodingMode == .fast {
            guard selectedClipFormat.supportsPassthrough else {
                isExporting = false
                exportStatusText = "Fast mode supports only MP4 and MOV."
                uiMessage = exportStatusText
                lastActivityState = .failed
                return
            }
            let asset = AVURLAsset(url: sourceURL)
            let preset = AVAssetExportPresetPassthrough

            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                isExporting = false
                exportStatusText = "Clip export failed: Unable to create passthrough export session"
                uiMessage = exportStatusText
                lastActivityState = .failed
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
                    self.exportTask = nil
                    self.activeExportSession = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    if self.exportCancellationRequested {
                        self.exportStatusText = "Clip export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                        return
                    }
                    switch session.status {
                    case .completed:
                        self.outputURL = destination
                        self.exportStatusText = "Clip export complete: \(destination.lastPathComponent)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .success
                    case .failed:
                        self.exportStatusText = "Clip export failed: \(session.error?.localizedDescription ?? "Unknown error")"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                    case .cancelled:
                        self.exportStatusText = "Clip export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                    default:
                        self.exportStatusText = "Clip export ended with status: \(session.status.rawValue)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
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
                    self.exportTask = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    self.exportStatusText = "Clip export failed: No ffmpeg executable found."
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                }
                return
            }

            let bitrateKbps = max(1000, Int((self.clipVideoBitrateMbps * 1000.0).rounded()))
            let audioBitrateKbps = min(max(64, self.clipAudioBitrateKbps), 320)
            // DO NOT REMOVE / DO NOT "SIMPLIFY" THIS SEEK PATTERN.
            // This exact hybrid seek flow (coarse pre-roll + fine seek) is required to
            // avoid recurring leading black-frame artifacts in advanced FFmpeg exports.
            // Required argument order:
            //   -ss <coarse> -i <source> -ss <fine> -t <duration>
            // If changed to a single -ss, pure post-input seek, or trim-only path,
            // black first frames have repeatedly returned in real-world long-GOP media.
            // Historical fixes: 9017353, 941372f.
            // Keep the 9017353 hybrid seek order, but with a larger preroll budget for
            // long-GOP media where 2.5s can still under-run first-frame references.
            let hybridSeekPreRoll = 6.0
            let coarseSeekSeconds = max(0.0, self.clipStartSeconds - hybridSeekPreRoll)
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
            var captionTempDirectory: URL?
            defer {
                if let captionTempDirectory {
                    try? FileManager.default.removeItem(at: captionTempDirectory)
                }
            }
            var ffmpegArgs = [
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

            if self.clipAdvancedBurnInCaptions {
                await MainActor.run {
                    self.exportProgress = max(self.exportProgress, 0.12)
                    self.exportStatusText = "Generating captions…"
                }
                let captionPrep = await self.prepareWhisperBurnInCaptions(
                    sourceURL: sourceURL,
                    ffmpegURL: ffmpegURL,
                    startSeconds: self.clipStartSeconds,
                    durationSeconds: clipDuration
                )
                if let prepared = captionPrep.preparation {
                    captionTempDirectory = prepared.tempDirectory
                    videoFilters.append(
                        self.subtitlesFilterArgument(
                            path: prepared.srtURL.path,
                            style: self.clipAdvancedCaptionStyle
                        )
                    )
                } else {
                    let reason = captionPrep.error ?? "Unknown caption generation failure."
                    await MainActor.run {
                        self.exportTask = nil
                        self.isExporting = false
                        self.exportProgress = 0
                        if self.exportCancellationRequested {
                            self.exportStatusText = "Clip export cancelled"
                            self.uiMessage = self.exportStatusText
                            self.lastActivityState = .cancelled
                            self.notifyCompletion("Compatible Clip Export Stopped", message: self.exportStatusText)
                        } else {
                            self.exportStatusText = "Clip export failed: \(reason)"
                            self.uiMessage = self.exportStatusText
                            self.lastActivityState = .failed
                            self.notifyCompletion("Compatible Clip Export Failed", message: self.exportStatusText)
                        }
                    }
                    return
                }
            }

            if applyAudioFade && hasSourceAudio {
                audioFilters.append("afade=t=in:st=0:d=\(String(format: "%.3f", fadeDuration))")
                audioFilters.append("afade=t=out:st=\(String(format: "%.3f", fadeOutStart)):d=\(String(format: "%.3f", fadeDuration))")
            }

            if self.clipAdvancedBoostAudio && hasSourceAudio {
                audioFilters.append("volume=10dB")
                audioFilters.append("alimiter=limit=0.988553")
            }

            if !videoFilters.isEmpty {
                ffmpegArgs.append(contentsOf: ["-vf", videoFilters.joined(separator: ",")])
            }

            if let selectedAudioTrackIndex {
                let audioInputRef = "0:a:\(selectedAudioTrackIndex)"
                if !audioFilters.isEmpty {
                    ffmpegArgs.append(contentsOf: [
                        "-filter_complex", "[\(audioInputRef)]\(audioFilters.joined(separator: ","))[aout]",
                        "-map", "[aout]"
                    ])
                } else {
                    ffmpegArgs.append(contentsOf: ["-map", audioInputRef])
                }
                ffmpegArgs.append(contentsOf: [
                    "-c:a", audioCodec,
                    "-b:a", "\(audioBitrateKbps)k"
                ])
            }

            if self.selectedClipFormat == .mp4 || self.selectedClipFormat == .mov {
                ffmpegArgs.append(contentsOf: ["-movflags", "+faststart"])
            }

            ffmpegArgs.append(destination.path)

            let advancedStatusPrefix = self.clipAdvancedBurnInCaptions ? "Burning captions" : "Encoding advanced clip"
            let encodeError = await self.runFFmpegProcessWithProgress(
                executableURL: ffmpegURL,
                arguments: ffmpegArgs,
                durationSeconds: clipDuration,
                statusPrefix: advancedStatusPrefix,
                progressRange: self.clipAdvancedBurnInCaptions ? (0.55...1.0) : nil
            )

            await MainActor.run {
                self.exportTask = nil
                self.isExporting = false
                self.exportProgress = 0
                if self.exportCancellationRequested {
                    self.exportStatusText = "Clip export cancelled"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .cancelled
                    self.notifyCompletion("Compatible Clip Export Stopped", message: self.exportStatusText)
                    return
                }
                if let encodeError {
                    self.exportStatusText = "Clip export failed: \(encodeError)"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                    self.notifyCompletion("Compatible Clip Export Failed", message: self.exportStatusText)
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
        startSeconds: Double,
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
        let start = String(format: "%.3f", startSeconds)
        let duration = String(format: "%.3f", max(0.001, durationSeconds))

        let extractError = await runFFmpegProcessWithProgress(
            executableURL: ffmpegURL,
            arguments: [
                "-y",
                "-hide_banner",
                "-loglevel", "error",
                "-ss", start,
                "-t", duration,
                "-i", sourceURL.path,
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

        return (BurnInCaptionPreparation(srtURL: srtURL, tempDirectory: tempDirectory), nil)
    }

    private func runProcess(executableURL: URL, arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = Pipe()

            do {
                try process.run()
                Task { @MainActor in
                    self.activeProcess = process
                }
            } catch {
                continuation.resume(returning: error.localizedDescription)
                return
            }

            process.terminationHandler = { proc in
                Task { @MainActor in
                    if self.activeProcess === proc {
                        self.activeProcess = nil
                    }
                }
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(decoding: data, as: UTF8.self)
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
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout

            func emitProgress(_ progress: Double) {
                Task { @MainActor in
                    guard self.isExporting else { return }
                    let clamped = min(max(progress, 0), 1)
                    let mapped = progressRange.lowerBound + ((progressRange.upperBound - progressRange.lowerBound) * clamped)
                    self.exportProgress = min(max(mapped, 0), 1)
                    self.exportStatusText = "\(statusPrefix)… \(Int((clamped * 100).rounded()))%"
                }
            }

            let parseChunk: (Data) -> Void = { data in
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    if let progress = extractPercentProgress(from: String(rawLine)) {
                        emitProgress(progress)
                    }
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                parseChunk(handle.availableData)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                parseChunk(handle.availableData)
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
                parseChunk(stdoutData)
                parseChunk(stderrData)

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
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments + ["-progress", "pipe:1", "-nostats"]

            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout

            let safeDuration = max(0.001, durationSeconds)
            var stdoutBuffer = Data()

            let emitProgress: (Double) -> Void = { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isExporting else { return }
                    let clamped = min(max(progress, 0), 1)
                    if let range = progressRange {
                        let mapped = range.lowerBound + ((range.upperBound - range.lowerBound) * clamped)
                        self.exportProgress = min(max(mapped, 0), 1)
                    } else {
                        self.exportProgress = clamped
                    }
                    self.exportStatusText = "\(statusPrefix)… \(Int((clamped * 100).rounded()))%"
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stdoutBuffer.append(chunk)

                while let newlineRange = stdoutBuffer.firstRange(of: Data([0x0A])) {
                    let lineData = stdoutBuffer.subdata(in: 0..<newlineRange.lowerBound)
                    stdoutBuffer.removeSubrange(0...newlineRange.lowerBound)
                    guard let rawLine = String(data: lineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          !rawLine.isEmpty else { continue }

                    if rawLine == "progress=end" {
                        emitProgress(1.0)
                        continue
                    }

                    if rawLine.hasPrefix("out_time_us="),
                       let microseconds = Double(rawLine.dropFirst("out_time_us=".count)) {
                        emitProgress((microseconds / 1_000_000.0) / safeDuration)
                        continue
                    }

                    if rawLine.hasPrefix("out_time_ms="),
                       let value = Double(rawLine.dropFirst("out_time_ms=".count)) {
                        // ffmpeg emits this value in microseconds.
                        emitProgress((value / 1_000_000.0) / safeDuration)
                        continue
                    }

                    if rawLine.hasPrefix("out_time="),
                       let seconds = parseTimecode(String(rawLine.dropFirst("out_time=".count))) {
                        emitProgress(seconds / safeDuration)
                    }
                }
            }

            do {
                try process.run()
                Task { @MainActor in
                    self.activeProcess = process
                }
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: error.localizedDescription)
                return
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
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

                let stderrText = String(decoding: stderrData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stdoutText = String(decoding: stdoutBuffer, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else if !stderrText.isEmpty {
                    continuation.resume(returning: stderrText)
                } else if !stdoutText.isEmpty {
                    continuation.resume(returning: stdoutText)
                } else {
                    continuation.resume(returning: "\(executableURL.lastPathComponent) exited with status \(proc.terminationStatus)")
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

    func addTimelineMarker(at seconds: Double) {
        addCaptureTimelineMarker(at: seconds)
        uiMessage = "Marker added at \(formatSeconds(seconds))"
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
        highlightedCaptureTimelineMarkerID = nearestTimelineMarker(to: seconds, tolerance: tolerance)?.id
    }

    func removeHighlightedTimelineMarker() -> Bool {
        guard let highlightedID = highlightedCaptureTimelineMarkerID,
              let index = captureTimelineMarkers.firstIndex(where: { $0.id == highlightedID }) else {
            return false
        }
        captureTimelineMarkers.remove(at: index)
        highlightedCaptureTimelineMarkerID = nil
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
