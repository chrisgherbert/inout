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

public struct TranscriptSegment: Identifiable {
    public let id: UUID
    public let start: Double
    public let end: Double
    public let text: String

    public init(id: UUID = UUID(), start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
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
    public let transcriptSegments: [TranscriptSegment]?
    public let mediaDuration: Double?

    public init(
        segments: [Segment],
        silentSegments: [Segment],
        profanityHits: [ProfanityHit],
        transcriptSegments: [TranscriptSegment]?,
        mediaDuration: Double?
    ) {
        self.segments = segments
        self.silentSegments = silentSegments
        self.profanityHits = profanityHits
        self.transcriptSegments = transcriptSegments
        self.mediaDuration = mediaDuration
    }
}

public struct FileAnalysis {
    public let fileURL: URL
    public var segments: [Segment]
    public var silentSegments: [Segment]
    public var profanityHits: [ProfanityHit]
    public var includedBlackDetection: Bool
    public var includedSilenceDetection: Bool
    public var includedProfanityDetection: Bool
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
        includedBlackDetection: Bool = true,
        includedSilenceDetection: Bool = true,
        includedProfanityDetection: Bool = false,
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
        self.includedBlackDetection = includedBlackDetection
        self.includedSilenceDetection = includedSilenceDetection
        self.includedProfanityDetection = includedProfanityDetection
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

    public var timelineDuration: Double? {
        if let mediaDuration, mediaDuration > 0 {
            return mediaDuration
        }
        let maxBlackEnd = segments.map(\.end).max() ?? 0
        let maxSilentEnd = silentSegments.map(\.end).max() ?? 0
        let maxProfanityEnd = profanityHits.map(\.end).max() ?? 0
        let maxEnd = max(maxBlackEnd, max(maxSilentEnd, maxProfanityEnd))
        return maxEnd > 0 ? maxEnd : nil
    }
}

public struct SourceMediaInfo {
    public var fileSizeBytes: Int64?
    public var durationSeconds: Double?
    public var overallBitrateBps: Double?
    public var containerDescription: String?
    public var videoCodec: String?
    public var resolution: String?
    public var frameRate: Double?
    public var videoBitrateBps: Double?
    public var colorPrimaries: String?
    public var colorTransfer: String?
    public var audioCodec: String?
    public var sampleRateHz: Double?
    public var channels: Int?
    public var audioBitrateBps: Double?

    public init(
        fileSizeBytes: Int64? = nil,
        durationSeconds: Double? = nil,
        overallBitrateBps: Double? = nil,
        containerDescription: String? = nil,
        videoCodec: String? = nil,
        resolution: String? = nil,
        frameRate: Double? = nil,
        videoBitrateBps: Double? = nil,
        colorPrimaries: String? = nil,
        colorTransfer: String? = nil,
        audioCodec: String? = nil,
        sampleRateHz: Double? = nil,
        channels: Int? = nil,
        audioBitrateBps: Double? = nil
    ) {
        self.fileSizeBytes = fileSizeBytes
        self.durationSeconds = durationSeconds
        self.overallBitrateBps = overallBitrateBps
        self.containerDescription = containerDescription
        self.videoCodec = videoCodec
        self.resolution = resolution
        self.frameRate = frameRate
        self.videoBitrateBps = videoBitrateBps
        self.colorPrimaries = colorPrimaries
        self.colorTransfer = colorTransfer
        self.audioCodec = audioCodec
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.audioBitrateBps = audioBitrateBps
    }
}
