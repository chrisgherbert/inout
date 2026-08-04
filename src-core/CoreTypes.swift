import Foundation

public let defaultMinSilenceDurationSeconds = 1.0
public let defaultProfanityWords: Set<String> = [
    "ass", "asshole", "bastard", "bitch", "bullshit", "crap", "damn",
    "dick", "douche", "douchebag", "fucker", "fucking", "fuck", "goddamn",
    "hell", "motherfucker", "pissed", "shit", "shitty", "slut", "whore"
]
public let defaultProfanityWordsStorageString = defaultProfanityWords.sorted().joined(separator: ", ")

public struct Segment: Identifiable {
    public let id: UUID
    public let start: Double
    public let end: Double
    public let duration: Double

    public init(id: UUID = UUID(), start: Double, end: Double, duration: Double) {
        self.id = id
        self.start = start
        self.end = end
        self.duration = duration
    }

    public var formatted: String {
        "\(formatSeconds(start)) → \(formatSeconds(end)) (\(String(format: "%.3f", duration))s)"
    }
}

public struct ProfanityHit: Identifiable {
    public let id: UUID
    public let start: Double
    public let end: Double
    public let duration: Double
    public let word: String

    public init(id: UUID = UUID(), start: Double, end: Double, duration: Double, word: String) {
        self.id = id
        self.start = start
        self.end = end
        self.duration = duration
        self.word = word
    }

    public var formatted: String {
        "\(formatSeconds(start)) → \(formatSeconds(end)) (\(word))"
    }
}

public enum BadEditIssueKind: String, Sendable {
    case blackFlash
    case visualFlash
    case suspiciouslyShortShot
    case frozenVideo
    case abruptAudioDiscontinuity
    case audioClippingAtEditPoint
    case streamMismatch
    case timestampDiscontinuity
    case decodeError
}

public enum BadEditConfidence: String, Sendable {
    case high
    case medium
}

public struct BadEditIssue: Identifiable, Sendable {
    public let id: UUID
    public let kind: BadEditIssueKind
    public let confidence: BadEditConfidence
    public let start: Double
    public let end: Double
    public let title: String
    public let detail: String

    public init(
        id: UUID = UUID(),
        kind: BadEditIssueKind,
        confidence: BadEditConfidence,
        start: Double,
        end: Double,
        title: String,
        detail: String
    ) {
        self.id = id
        self.kind = kind
        self.confidence = confidence
        self.start = start
        self.end = max(start, end)
        self.title = title
        self.detail = detail
    }

    public var duration: Double {
        max(0, end - start)
    }

    public var formatted: String {
        "\(formatSeconds(start)) -> \(formatSeconds(end))  \(title): \(detail)"
    }
}

public struct TranscriptWordTiming: Sendable {
    public let word: String
    public let start: Double
    public let end: Double

    public init(word: String, start: Double, end: Double) {
        self.word = word
        self.start = start
        self.end = end
    }
}

public struct TranscriptSegment: Identifiable, Sendable {
    public let id: UUID
    public let start: Double
    public let end: Double
    public let text: String
    public let timedWords: [TranscriptWordTiming]

    public init(
        id: UUID = UUID(),
        start: Double,
        end: Double,
        text: String,
        timedWords: [TranscriptWordTiming] = []
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.timedWords = timedWords
    }

    public var duration: Double {
        max(0, end - start)
    }

    public var formatted: String {
        "\(formatSeconds(start)) → \(formatSeconds(end))  \(text)"
    }
}

public enum FileStatus {
    case idle
    case running
    case done
    case failed(String)
}

public enum DetectionError: Error {
    case failed(String)
    case cancelled
}

public struct DetectionOutput {
    public let segments: [Segment]
    public let silentSegments: [Segment]
    public let profanityHits: [ProfanityHit]
    public let badEditIssues: [BadEditIssue]
    public let transcriptSegments: [TranscriptSegment]?
    public let mediaDuration: Double?

    public init(
        segments: [Segment],
        silentSegments: [Segment],
        profanityHits: [ProfanityHit],
        badEditIssues: [BadEditIssue] = [],
        transcriptSegments: [TranscriptSegment]?,
        mediaDuration: Double?
    ) {
        self.segments = segments
        self.silentSegments = silentSegments
        self.profanityHits = profanityHits
        self.badEditIssues = badEditIssues
        self.transcriptSegments = transcriptSegments
        self.mediaDuration = mediaDuration
    }
}

public struct FileAnalysis {
    public let fileURL: URL
    public var segments: [Segment]
    public var silentSegments: [Segment]
    public var profanityHits: [ProfanityHit]
    public var badEditIssues: [BadEditIssue]
    public var includedBlackDetection: Bool
    public var includedSilenceDetection: Bool
    public var includedProfanityDetection: Bool
    public var includedBadEditDetection: Bool
    public var profanityWordsSnapshot: String
    public var silenceMinDurationSeconds: Double
    public var mediaDuration: Double?
    public var progress: Double
    public var status: FileStatus

    public init(
        fileURL: URL,
        segments: [Segment] = [],
        silentSegments: [Segment] = [],
        profanityHits: [ProfanityHit] = [],
        badEditIssues: [BadEditIssue] = [],
        includedBlackDetection: Bool = true,
        includedSilenceDetection: Bool = true,
        includedProfanityDetection: Bool = false,
        includedBadEditDetection: Bool = false,
        profanityWordsSnapshot: String = defaultProfanityWordsStorageString,
        silenceMinDurationSeconds: Double = defaultMinSilenceDurationSeconds,
        mediaDuration: Double? = nil,
        progress: Double = 0,
        status: FileStatus = .idle
    ) {
        self.fileURL = fileURL
        self.segments = segments
        self.silentSegments = silentSegments
        self.profanityHits = profanityHits
        self.badEditIssues = badEditIssues
        self.includedBlackDetection = includedBlackDetection
        self.includedSilenceDetection = includedSilenceDetection
        self.includedProfanityDetection = includedProfanityDetection
        self.includedBadEditDetection = includedBadEditDetection
        self.profanityWordsSnapshot = profanityWordsSnapshot
        self.silenceMinDurationSeconds = silenceMinDurationSeconds
        self.mediaDuration = mediaDuration
        self.progress = progress
        self.status = status
    }

    public var totalDuration: Double {
        segments.reduce(0.0) { $0 + $1.duration }
    }

    public var totalSilentDuration: Double {
        silentSegments.reduce(0.0) { $0 + $1.duration }
    }

    public var summary: String {
        switch status {
        case .idle:
            return "Ready"
        case .running:
            return "Analyzing… \(Int((progress * 100).rounded()))%"
        case .done:
            var pieces: [String] = []
            if includedBlackDetection {
                if segments.isEmpty {
                    pieces.append("No black segments")
                } else {
                    pieces.append("\(segments.count) black segment(s), \(String(format: "%.3f", totalDuration))s")
                }
            }
            if includedSilenceDetection {
                if silentSegments.isEmpty {
                    pieces.append("No silent gaps")
                } else {
                    pieces.append("\(silentSegments.count) silent gap(s), \(String(format: "%.3f", totalSilentDuration))s")
                }
            }
            if includedProfanityDetection {
                if profanityHits.isEmpty {
                    pieces.append("No profanity detected")
                } else {
                    pieces.append("\(profanityHits.count) profanity hit(s)")
                }
            }
            if includedBadEditDetection {
                if badEditIssues.isEmpty {
                    pieces.append("No possible bad edits")
                } else {
                    pieces.append("\(badEditIssues.count) possible bad edit(s)")
                }
            }
            return pieces.isEmpty ? "No analysis type enabled" : pieces.joined(separator: " • ")
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }

    public var formattedList: String {
        segments.map(\.formatted).joined(separator: "\n")
    }

    public var formattedSilentList: String {
        silentSegments.map(\.formatted).joined(separator: "\n")
    }

    public var formattedProfanityList: String {
        profanityHits.map(\.formatted).joined(separator: "\n")
    }

    public var formattedBadEditList: String {
        badEditIssues.map(\.formatted).joined(separator: "\n")
    }

    public var timelineDuration: Double? {
        if let mediaDuration, mediaDuration > 0 {
            return mediaDuration
        }
        let maxBlackEnd = segments.map(\.end).max() ?? 0
        let maxSilentEnd = silentSegments.map(\.end).max() ?? 0
        let maxProfanityEnd = profanityHits.map(\.end).max() ?? 0
        let maxBadEditEnd = badEditIssues.map(\.end).max() ?? 0
        let maxEnd = max(maxBlackEnd, max(maxSilentEnd, max(maxProfanityEnd, maxBadEditEnd)))
        return maxEnd > 0 ? maxEnd : nil
    }
}

public struct SourceMediaInfo {
    public var fileSizeBytes: Int64?
    public var durationSeconds: Double?
    public var overallBitrateBps: Double?
    public var containerDescription: String?
    public var videoStreamCount: Int
    public var videoCodec: String?
    public var resolution: String?
    public var frameRate: Double?
    public var videoBitrateBps: Double?
    public var colorPrimaries: String?
    public var colorTransfer: String?
    public var videoStartSeconds: Double?
    public var videoDurationSeconds: Double?
    public var audioStreamCount: Int
    public var audioCodec: String?
    public var sampleRateHz: Double?
    public var channels: Int?
    public var audioBitrateBps: Double?
    public var audioStartSeconds: Double?
    public var audioDurationSeconds: Double?

    public init(
        fileSizeBytes: Int64? = nil,
        durationSeconds: Double? = nil,
        overallBitrateBps: Double? = nil,
        containerDescription: String? = nil,
        videoStreamCount: Int = 0,
        videoCodec: String? = nil,
        resolution: String? = nil,
        frameRate: Double? = nil,
        videoBitrateBps: Double? = nil,
        colorPrimaries: String? = nil,
        colorTransfer: String? = nil,
        videoStartSeconds: Double? = nil,
        videoDurationSeconds: Double? = nil,
        audioStreamCount: Int = 0,
        audioCodec: String? = nil,
        sampleRateHz: Double? = nil,
        channels: Int? = nil,
        audioBitrateBps: Double? = nil,
        audioStartSeconds: Double? = nil,
        audioDurationSeconds: Double? = nil
    ) {
        self.fileSizeBytes = fileSizeBytes
        self.durationSeconds = durationSeconds
        self.overallBitrateBps = overallBitrateBps
        self.containerDescription = containerDescription
        self.videoStreamCount = videoStreamCount
        self.videoCodec = videoCodec
        self.resolution = resolution
        self.frameRate = frameRate
        self.videoBitrateBps = videoBitrateBps
        self.colorPrimaries = colorPrimaries
        self.colorTransfer = colorTransfer
        self.videoStartSeconds = videoStartSeconds
        self.videoDurationSeconds = videoDurationSeconds
        self.audioStreamCount = audioStreamCount
        self.audioCodec = audioCodec
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.audioBitrateBps = audioBitrateBps
        self.audioStartSeconds = audioStartSeconds
        self.audioDurationSeconds = audioDurationSeconds
    }
}
