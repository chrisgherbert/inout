import AppKit
import AVFoundation
import Foundation
import InOutCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let clipSetStartAtPlayhead = Notification.Name("clipSetStartAtPlayhead")
    static let clipSetEndAtPlayhead = Notification.Name("clipSetEndAtPlayhead")
    static let clipClearRange = Notification.Name("clipClearRange")
    static let clipAddMarkerAtPlayhead = Notification.Name("clipAddMarkerAtPlayhead")
    static let clipJumpToStart = Notification.Name("clipJumpToStart")
    static let clipJumpToEnd = Notification.Name("clipJumpToEnd")
    static let clipCaptureFrame = Notification.Name("clipCaptureFrame")
    static let clipTimelineZoomIn = Notification.Name("clipTimelineZoomIn")
    static let clipTimelineZoomOut = Notification.Name("clipTimelineZoomOut")
    static let clipTimelineZoomReset = Notification.Name("clipTimelineZoomReset")
    static let clipFocusTranscriptSearch = Notification.Name("clipFocusTranscriptSearch")
    static let clipToggleTranscriptSidebar = Notification.Name("clipToggleTranscriptSidebar")
}

private struct WorkspaceModelFocusedValueKey: FocusedValueKey {
    typealias Value = WorkspaceViewModel
}

extension FocusedValues {
    var workspaceModel: WorkspaceViewModel? {
        get { self[WorkspaceModelFocusedValueKey.self] }
        set { self[WorkspaceModelFocusedValueKey.self] = newValue }
    }
}

let minDurationSeconds = InOutCore.minDurationSeconds
let defaultMinSilenceDurationSeconds = InOutCore.defaultMinSilenceDurationSeconds
let silenceAmplitudeThreshold = InOutCore.silenceAmplitudeThreshold
let defaultAdvancedClipFilenameTemplate = "{source_name}_clip_{in_tc}_to_{out_tc}"
let defaultProfanityWords = InOutCore.defaultProfanityWords
let defaultProfanityWordsStorageString = InOutCore.defaultProfanityWordsStorageString

enum UIRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
}

enum WorkspaceTool: String, CaseIterable, Identifiable {
    case clip = "Clip"
    case analyze = "Analyze"
    case convert = "Convert"
    case inspect = "Inspect"

    var id: String { rawValue }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case mp3 = "MP3"
    case m4a = "M4A"

    var id: String { rawValue }
}

enum ClipFormat: String, CaseIterable, Identifiable {
    case mp4 = "MP4"
    case mov = "MOV"
    case mkv = "MKV"
    case webm = "WebM"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .mov: return "mov"
        case .mkv: return "mkv"
        case .webm: return "webm"
        }
    }

    var fileType: AVFileType {
        switch self {
        case .mp4: return .mp4
        case .mov: return .mov
        case .mkv: return .mov
        case .webm: return .mov
        }
    }

    var contentType: UTType {
        switch self {
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        case .mkv: return UTType(filenameExtension: "mkv") ?? .data
        case .webm: return UTType(filenameExtension: "webm") ?? .data
        }
    }

    var supportsPassthrough: Bool {
        switch self {
        case .mp4, .mov:
            return true
        case .mkv, .webm:
            return false
        }
    }
}

enum ClipEncodingMode: String, CaseIterable, Identifiable {
    case fast = "Fast (Original)"
    case compressed = "Advanced"
    case audioOnly = "Audio Only"

    var id: String { rawValue }
}

enum ClipAudioOnlyFormat: String, CaseIterable, Identifiable {
    case mp3 = "MP3"
    case m4a = "M4A"
    case wav = "WAV"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .mp3: return "mp3"
        case .m4a: return "m4a"
        case .wav: return "wav"
        }
    }

    var contentType: UTType {
        switch self {
        case .mp3: return .mp3
        case .m4a: return .mpeg4Audio
        case .wav: return .wav
        }
    }
}

enum CompatibleSpeedPreset: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case balanced = "Balanced"
    case quality = "Quality"

    var id: String { rawValue }

    var ffmpegPreset: String {
        switch self {
        case .fast: return "veryfast"
        case .balanced: return "medium"
        case .quality: return "slow"
        }
    }
}

enum CompatibleMaxResolution: String, CaseIterable, Identifiable {
    case original = "Original"
    case p1080 = "1080p"
    case p720 = "720p"
    case p480 = "480p"

    var id: String { rawValue }

    var scaleFilter: String? {
        switch self {
        case .original:
            return nil
        case .p1080:
            return "scale='min(iw,1920)':'min(ih,1080)':force_original_aspect_ratio=decrease:force_divisible_by=2"
        case .p720:
            return "scale='min(iw,1280)':'min(ih,720)':force_original_aspect_ratio=decrease:force_divisible_by=2"
        case .p480:
            return "scale='min(iw,854)':'min(ih,480)':force_original_aspect_ratio=decrease:force_divisible_by=2"
        }
    }
}

enum AdvancedVideoCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC (H.265)"

    var id: String { rawValue }
}

enum AdvancedBoostAmount: Int, CaseIterable, Identifiable {
    case db5 = 5
    case db10 = 10
    case db15 = 15
    case db20 = 20
    case db25 = 25
    case db30 = 30

    var id: Int { rawValue }

    var label: String { "\(rawValue)dB" }
}

enum BurnInCaptionStyle: String, CaseIterable, Identifiable {
    case youtube = "YouTube"
    case netflix = "Netflix"
    case crunchyroll = "Crunchyroll"
    case vintageYellow = "Vintage Yellow"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .youtube:
            return "Roboto with soft boxed readability."
        case .netflix:
            return "Consolas with dark backdrop and compact spacing."
        case .vintageYellow:
            return "Italic warm-yellow subtitle treatment."
        case .crunchyroll:
            return "Simple Trebuchet MS styling."
        }
    }

    var ffmpegForceStyle: String {
        switch self {
        case .youtube:
            return "Fontname=Roboto,OutlineColour=&H40000000,BorderStyle=3,MarginV=48,Alignment=2"
        case .netflix:
            return "Fontname=Consolas,BackColour=&H80000000,Spacing=0.2,Outline=0,Shadow=0.75,MarginV=48,Alignment=2"
        case .vintageYellow:
            return "PrimaryColour=&H03fcff,Italic=1,Spacing=0.8,MarginV=48,Alignment=2"
        case .crunchyroll:
            return "Fontname=Trebuchet MS,MarginV=48,Alignment=2"
        }
    }
}

enum AdvancedFilenamePreset: String, CaseIterable, Identifiable {
    case sourceClipInOut = "Source + Clip Range"
    case sourceInOutDate = "Source + Range + Date"
    case dateSourceRange = "Date + Source + Range"
    case sourceCodecRange = "Source + Codec + Range"
    case sourceResolutionRange = "Source + Resolution + Range"

    var id: String { rawValue }

    var template: String {
        switch self {
        case .sourceClipInOut:
            return "{source_name}_clip_{in_tc}_to_{out_tc}"
        case .sourceInOutDate:
            return "{source_name}_{in_tc}_to_{out_tc}_{date}"
        case .dateSourceRange:
            return "{date}_{source_name}_{in_tc}_to_{out_tc}"
        case .sourceCodecRange:
            return "{source_name}_{codec}_{in_tc}_to_{out_tc}"
        case .sourceResolutionRange:
            return "{source_name}_{resolution}_{in_tc}_to_{out_tc}"
        }
    }
}

enum CompletionSound: String, CaseIterable, Identifiable {
    case crystal
    case glass
    case basso
    case funk
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .crystal: return "Crystal"
        case .glass: return "Glass"
        case .basso: return "Basso"
        case .funk: return "Funk"
        case .none: return "None"
        }
    }

    var soundName: NSSound.Name? {
        switch self {
        case .crystal: return NSSound.Name("Crystal")
        case .glass: return NSSound.Name("Glass")
        case .basso: return NSSound.Name("Basso")
        case .funk: return NSSound.Name("Funk")
        case .none: return nil
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "Follow System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum FrameSaveLocationMode: String, CaseIterable, Identifiable {
    case askEachTime = "Ask Each Time"
    case sourceFolder = "Source Folder"
    case customFolder = "Custom Folder"

    var id: String { rawValue }
}

enum URLDownloadPreset: String, CaseIterable, Identifiable {
    case compatibleBest = "Best Compatible"
    case compatible1080 = "1080p Compatible"
    case compatible720 = "720p Compatible"
    case bestAnyToMP4 = "Best Available"
    case audioOnly = "Audio Only"

    var id: String { rawValue }

    var outputExtension: String {
        switch self {
        case .audioOnly:
            return "mp3"
        default:
            return "mp4"
        }
    }

    var requiresTranscodeWarning: Bool {
        self == .bestAnyToMP4
    }
}

enum URLDownloadSaveLocationMode: String, CaseIterable, Identifiable {
    case askEachTime = "Ask Each Time"
    case downloadsFolder = "Downloads Folder"
    case customFolder = "Custom Folder"

    var id: String { rawValue }
}

typealias Segment = InOutCore.Segment

struct CaptureTimelineMarker: Identifiable, Equatable {
    let id = UUID()
    let seconds: Double
}

enum ClipBoundaryHighlight: Equatable {
    case start
    case end
}

typealias ProfanityHit = InOutCore.ProfanityHit
typealias TranscriptSegment = InOutCore.TranscriptSegment
typealias FileStatus = InOutCore.FileStatus
typealias DetectionError = InOutCore.DetectionError

enum ActivityState {
    case idle
    case running
    case success
    case failed
    case cancelled
}

final class CancellationFlag {
    private let lock = NSLock()
    private var cancelled = false

    func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

typealias DetectionOutput = InOutCore.DetectionOutput
typealias FileAnalysis = InOutCore.FileAnalysis
typealias SourceMediaInfo = InOutCore.SourceMediaInfo
