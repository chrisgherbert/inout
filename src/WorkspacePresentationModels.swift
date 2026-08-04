import Foundation
import SwiftUI

@MainActor
final class AnalysisCheckPreferencesModel: ObservableObject {
    private enum DefaultsKey {
        static let blackFrames = "prefs.analyzeBlackFrames"
        static let badEdits = "prefs.analyzeBadEdits"
        static let audioSilence = "prefs.analyzeAudioSilence"
        static let profanity = "prefs.analyzeProfanity"
    }

    private let defaults: UserDefaults

    @Published var blackFrames: Bool {
        didSet { defaults.set(blackFrames, forKey: DefaultsKey.blackFrames) }
    }
    @Published var badEdits: Bool {
        didSet { defaults.set(badEdits, forKey: DefaultsKey.badEdits) }
    }
    @Published var audioSilence: Bool {
        didSet { defaults.set(audioSilence, forKey: DefaultsKey.audioSilence) }
    }
    @Published var profanity: Bool {
        didSet { defaults.set(profanity, forKey: DefaultsKey.profanity) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        blackFrames = defaults.bool(forKey: DefaultsKey.blackFrames)
        badEdits = defaults.bool(forKey: DefaultsKey.badEdits)
        audioSilence = defaults.bool(forKey: DefaultsKey.audioSilence)
        profanity = defaults.bool(forKey: DefaultsKey.profanity)
    }
}

@MainActor
final class SourcePresentationModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var sourceSessionID = UUID()
    @Published var analysis: FileAnalysis?
    @Published var sourceInfo: SourceMediaInfo?
    @Published var transcriptSegments: [TranscriptSegment] = []
    @Published var transcriptStatusText = "No transcript generated yet."
    @Published var hasCachedTranscript = false
    @Published var isGeneratingTranscript = false

    var hasVideoTrack: Bool {
        guard let sourceInfo else { return false }
        if let bitrate = sourceInfo.videoBitrateBps, bitrate > 0 { return true }
        if let frameRate = sourceInfo.frameRate, frameRate > 0 { return true }
        if let resolution = sourceInfo.resolution, !resolution.isEmpty { return true }
        if let codec = sourceInfo.videoCodec, !codec.isEmpty { return true }
        return false
    }

    var hasAudioTrack: Bool {
        guard let sourceInfo else { return false }
        if let bitrate = sourceInfo.audioBitrateBps, bitrate > 0 { return true }
        if let sampleRate = sourceInfo.sampleRateHz, sampleRate > 0 { return true }
        if let channels = sourceInfo.channels, channels > 0 { return true }
        if let codec = sourceInfo.audioCodec, !codec.isEmpty { return true }
        return false
    }

    var sourceDurationSeconds: Double {
        max(0, sourceInfo?.durationSeconds ?? analysis?.mediaDuration ?? 0)
    }
}

@MainActor
final class ClipTimelinePresentationModel: ObservableObject {
    @Published var captureTimelineMarkers: [CaptureTimelineMarker] = []
    @Published var highlightedCaptureTimelineMarkerID: UUID?
    @Published var highlightedClipBoundary: ClipBoundaryHighlight?
    @Published var captureFrameFlashToken: Int = 0
    @Published var quickExportFlashToken: Int = 0
    @Published var clipStartSeconds: Double = 0
    @Published var clipEndSeconds: Double = 0
    @Published var clipPlayheadSeconds: Double = 0
    @Published var clipStartText = "00:00:00.000"
    @Published var clipEndText = "00:00:00.000"

    var clipDurationSeconds: Double {
        max(0, clipEndSeconds - clipStartSeconds)
    }
}
