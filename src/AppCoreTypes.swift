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

struct AppShortcutDefinition: Identifiable {
    let id: String
    let action: String
    let keys: [String]
    let keyEquivalent: KeyEquivalent?
    let modifiers: EventModifiers

    init(
        id: String,
        action: String,
        keys: [String],
        keyEquivalent: KeyEquivalent? = nil,
        modifiers: EventModifiers = []
    ) {
        self.id = id
        self.action = action
        self.keys = keys
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
    }
}

struct AppShortcutGroupDefinition: Identifiable {
    let id: String
    let title: String
    let items: [AppShortcutDefinition]
}

enum AppShortcutCatalog {
    static let playPause = AppShortcutDefinition(id: "playPause", action: "Play or pause", keys: ["Space"])
    static let playSelection = AppShortcutDefinition(id: "playSelection", action: "Play selection only", keys: ["⌃", "Space"])
    static let shuttleBackward = AppShortcutDefinition(id: "shuttleBackward", action: "Shuttle backward", keys: ["J"])
    static let shuttlePause = AppShortcutDefinition(id: "shuttlePause", action: "Pause shuttle", keys: ["K"])
    static let shuttleForward = AppShortcutDefinition(id: "shuttleForward", action: "Shuttle forward", keys: ["L"])

    static let setClipStart = AppShortcutDefinition(id: "setClipStart", action: "Set In", keys: ["I"], keyEquivalent: "i")
    static let setClipEnd = AppShortcutDefinition(id: "setClipEnd", action: "Set Out", keys: ["O"], keyEquivalent: "o")
    static let clearClipRange = AppShortcutDefinition(id: "clearClipRange", action: "Clear In and Out", keys: ["X"], keyEquivalent: "x")
    static let selectFullSource = AppShortcutDefinition(id: "selectFullSource", action: "Select full source", keys: ["⌘", "A"])
    static let stepBackwardTenFrames = AppShortcutDefinition(id: "stepBackwardTenFrames", action: "Step backward 10 frames", keys: ["⇧", "←"])
    static let stepForwardTenFrames = AppShortcutDefinition(id: "stepForwardTenFrames", action: "Step forward 10 frames", keys: ["⇧", "→"])

    static let addMarker = AppShortcutDefinition(id: "addMarker", action: "Add marker", keys: ["M"], keyEquivalent: "m")
    static let previousMarker = AppShortcutDefinition(id: "previousMarker", action: "Previous marker or edge", keys: ["↑"], keyEquivalent: .upArrow)
    static let nextMarker = AppShortcutDefinition(id: "nextMarker", action: "Next marker or edge", keys: ["↓"], keyEquivalent: .downArrow)
    static let deleteMarker = AppShortcutDefinition(id: "deleteMarker", action: "Delete selected marker", keys: ["Delete"])
    static let backspaceDeleteMarker = AppShortcutDefinition(id: "backspaceDeleteMarker", action: "Delete selected marker", keys: ["Backspace"])
    static let jumpTimelineStart = AppShortcutDefinition(id: "jumpTimelineStart", action: "Jump to timeline start", keys: ["Home"])
    static let jumpTimelineEnd = AppShortcutDefinition(id: "jumpTimelineEnd", action: "Jump to timeline end", keys: ["End"])

    static let zoomIn = AppShortcutDefinition(id: "zoomIn", action: "Zoom in", keys: ["="])
    static let zoomOut = AppShortcutDefinition(id: "zoomOut", action: "Zoom out", keys: ["-"])
    static let commandZoomIn = AppShortcutDefinition(id: "commandZoomIn", action: "Zoom in", keys: ["⌘", "+"], keyEquivalent: "=", modifiers: [.command])
    static let commandZoomOut = AppShortcutDefinition(id: "commandZoomOut", action: "Zoom out", keys: ["⌘", "-"], keyEquivalent: "-", modifiers: [.command])
    static let fitTimeline = AppShortcutDefinition(id: "fitTimeline", action: "Fit timeline", keys: ["⌘", "0"], keyEquivalent: "0", modifiers: [.command])
    static let switchToClip = AppShortcutDefinition(id: "switchToClip", action: "Switch to Clip", keys: ["⌘", "1"], keyEquivalent: "1", modifiers: [.command])
    static let switchToAnalyze = AppShortcutDefinition(id: "switchToAnalyze", action: "Switch to Analyze", keys: ["⌘", "2"], keyEquivalent: "2", modifiers: [.command])
    static let switchToConvert = AppShortcutDefinition(id: "switchToConvert", action: "Switch to Convert", keys: ["⌘", "3"], keyEquivalent: "3", modifiers: [.command])
    static let switchToInspect = AppShortcutDefinition(id: "switchToInspect", action: "Switch to Inspect", keys: ["⌘", "4"], keyEquivalent: "4", modifiers: [.command])

    static let openMedia = AppShortcutDefinition(id: "openMedia", action: "Open media", keys: ["⌘", "O"], keyEquivalent: "o", modifiers: [.command])
    static let downloadMediaFromURL = AppShortcutDefinition(id: "downloadMediaFromURL", action: "Download media from URL", keys: ["⌘", "⇧", "O"], keyEquivalent: "o", modifiers: [.command, .shift])
    static let exportClip = AppShortcutDefinition(id: "exportClip", action: "Export clip", keys: ["⌘", "E"], keyEquivalent: "e", modifiers: [.command])
    static let quickExportClip = AppShortcutDefinition(id: "quickExportClip", action: "Quick export clip", keys: ["⌘", "⇧", "E"], keyEquivalent: "e", modifiers: [.command, .shift])
    static let exportAudio = AppShortcutDefinition(id: "exportAudio", action: "Export audio", keys: ["⌘", "⌥", "E"], keyEquivalent: "e", modifiers: [.command, .option])
    static let stopCurrentTask = AppShortcutDefinition(id: "stopCurrentTask", action: "Stop current task", keys: ["⌘", "."], keyEquivalent: ".", modifiers: [.command])
    static let openHelp = AppShortcutDefinition(id: "openHelp", action: "Open Help", keys: ["⌘", "⇧", "/"], keyEquivalent: "/", modifiers: [.command, .shift])
    static let toggleTranscript = AppShortcutDefinition(id: "toggleTranscript", action: "Toggle transcript", keys: ["⌘", "⇧", "T"], keyEquivalent: "t", modifiers: [.command, .shift])
    static let findInTranscript = AppShortcutDefinition(id: "findInTranscript", action: "Find in transcript", keys: ["⌘", "F"], keyEquivalent: "f", modifiers: [.command])

    static let helpGroups: [AppShortcutGroupDefinition] = [
        AppShortcutGroupDefinition(
            id: "playback",
            title: "Playback",
            items: [playPause, playSelection, shuttleBackward, shuttlePause, shuttleForward]
        ),
        AppShortcutGroupDefinition(
            id: "trimAndSelection",
            title: "Trim and selection",
            items: [setClipStart, setClipEnd, clearClipRange, selectFullSource, stepBackwardTenFrames, stepForwardTenFrames]
        ),
        AppShortcutGroupDefinition(
            id: "markersAndNavigation",
            title: "Markers and navigation",
            items: [addMarker, previousMarker, nextMarker, deleteMarker, backspaceDeleteMarker, jumpTimelineStart, jumpTimelineEnd]
        ),
        AppShortcutGroupDefinition(
            id: "zoomAndTools",
            title: "Zoom and tools",
            items: [zoomIn, zoomOut, commandZoomIn, commandZoomOut, fitTimeline, switchToClip, switchToAnalyze, switchToConvert, switchToInspect]
        ),
        AppShortcutGroupDefinition(
            id: "fileExportAndHelp",
            title: "File, export, and help",
            items: [openMedia, downloadMediaFromURL, exportClip, quickExportClip, exportAudio, stopCurrentTask, openHelp]
        )
    ]
}

extension View {
    @ViewBuilder
    func appKeyboardShortcut(_ shortcut: AppShortcutDefinition) -> some View {
        if let keyEquivalent = shortcut.keyEquivalent {
            keyboardShortcut(keyEquivalent, modifiers: shortcut.modifiers)
        } else {
            self
        }
    }
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

    var helpText: String {
        switch self {
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

    var badgeText: String? {
        switch self {
        case .compatibleBest:
            return "Recommended"
        case .bestAnyToMP4:
            return "Slow"
        default:
            return nil
        }
    }

    var badgeTint: Color {
        switch self {
        case .compatibleBest:
            return .accentColor
        case .bestAnyToMP4:
            return .red
        default:
            return .clear
        }
    }
}

extension URLDownloadAuthenticationMode {
    var helpText: String? {
        switch self {
        case .none:
            return nil
        case .browserCookies:
            return "Uses yt-dlp's browser cookie import to access your existing signed-in session."
        }
    }
}

enum URLDownloadSaveLocationMode: String, CaseIterable, Identifiable {
    case askEachTime = "Ask Each Time"
    case downloadsFolder = "Downloads Folder"
    case customFolder = "Custom Folder"

    var id: String { rawValue }
}

enum URLDownloadAuthenticationMode: String, CaseIterable, Identifiable {
    case none = "None"
    case browserCookies = "Use Browser Cookies"

    var id: String { rawValue }
}

enum URLDownloadBrowserCookiesSource: String, CaseIterable, Identifiable {
    case firefox = "Firefox"
    case chrome = "Chrome"
    case brave = "Brave"
    case edge = "Edge"
    case safari = "Safari"

    var id: String { rawValue }

    var ytDLPArgument: String {
        switch self {
        case .firefox:
            return "firefox"
        case .chrome:
            return "chrome"
        case .brave:
            return "brave"
        case .edge:
            return "edge"
        case .safari:
            return "safari"
        }
    }
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
