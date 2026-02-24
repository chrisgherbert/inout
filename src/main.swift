import AppKit
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine
import UserNotifications

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

private let minDurationSeconds = 0.001
let defaultMinSilenceDurationSeconds = 1.0
private let silenceAmplitudeThreshold = 0.01
let defaultAdvancedClipFilenameTemplate = "{source_name}_clip_{in_tc}_to_{out_tc}"
private let defaultProfanityWords: Set<String> = [
    "ass", "asshole", "bastard", "bitch", "bullshit", "crap", "damn",
    "dick", "douche", "douchebag", "fucker", "fucking", "fuck", "goddamn",
    "hell", "motherfucker", "pissed", "shit", "shitty", "slut", "whore"
]
let defaultProfanityWordsStorageString = defaultProfanityWords.sorted().joined(separator: ", ")
private let picThreshold = 0.90
private let pixelBlackThreshold = 0.10
private let maxSampleDimension = 640
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
    case vintageYellow = "Vintage Yellow"
    case crunchyroll = "Crunchyroll"

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

struct Segment: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    let duration: Double

    var formatted: String {
        "\(formatSeconds(start)) → \(formatSeconds(end)) (\(String(format: "%.3f", duration))s)"
    }
}

struct CaptureTimelineMarker: Identifiable, Equatable {
    let id = UUID()
    let seconds: Double
}

enum ClipBoundaryHighlight: Equatable {
    case start
    case end
}

struct ProfanityHit: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    let duration: Double
    let word: String

    var formatted: String {
        "\(formatSeconds(start)) → \(formatSeconds(end)) (\(word))"
    }
}

struct TranscriptSegment: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    let text: String

    var duration: Double {
        max(0, end - start)
    }

    var formatted: String {
        "\(formatSeconds(start)) → \(formatSeconds(end))  \(text)"
    }
}

enum FileStatus {
    case idle
    case running
    case done
    case failed(String)
}

enum DetectionError: Error {
    case failed(String)
    case cancelled
}

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

struct DetectionOutput {
    let segments: [Segment]
    let silentSegments: [Segment]
    let profanityHits: [ProfanityHit]
    let transcriptSegments: [TranscriptSegment]?
    let mediaDuration: Double?
}

struct FileAnalysis {
    let fileURL: URL
    var segments: [Segment] = []
    var silentSegments: [Segment] = []
    var profanityHits: [ProfanityHit] = []
    var includedBlackDetection: Bool = true
    var includedSilenceDetection: Bool = true
    var includedProfanityDetection: Bool = false
    var profanityWordsSnapshot: String = defaultProfanityWordsStorageString
    var silenceMinDurationSeconds: Double = defaultMinSilenceDurationSeconds
    var mediaDuration: Double?
    var progress: Double = 0
    var status: FileStatus = .idle

    var totalDuration: Double {
        segments.reduce(0.0) { $0 + $1.duration }
    }

    var totalSilentDuration: Double {
        silentSegments.reduce(0.0) { $0 + $1.duration }
    }

    var summary: String {
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

    var formattedList: String {
        segments.map(\.formatted).joined(separator: "\n")
    }

    var formattedSilentList: String {
        silentSegments.map(\.formatted).joined(separator: "\n")
    }

    var formattedProfanityList: String {
        profanityHits.map(\.formatted).joined(separator: "\n")
    }

    var timelineDuration: Double? {
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

struct SourceMediaInfo {
    var fileSizeBytes: Int64?
    var durationSeconds: Double?
    var overallBitrateBps: Double?
    var containerDescription: String?

    var videoCodec: String?
    var resolution: String?
    var frameRate: Double?
    var videoBitrateBps: Double?
    var colorPrimaries: String?
    var colorTransfer: String?

    var audioCodec: String?
    var sampleRateHz: Double?
    var channels: Int?
    var audioBitrateBps: Double?
}

func formatSeconds(_ value: Double) -> String {
    let whole = Int(value)
    let h = whole / 3600
    let m = (whole % 3600) / 60
    let s = whole % 60
    let ms = Int(((value - floor(value)) * 1000.0).rounded())
    return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
}

func formatBitrate(_ bps: Double?) -> String {
    guard let bps, bps > 0 else { return "—" }
    let kbps = bps / 1000.0
    if kbps >= 1000 {
        return String(format: "%.2f Mbps", kbps / 1000.0)
    }
    return String(format: "%.0f kbps", kbps)
}

func formatFileSize(_ bytes: Int64?) -> String {
    guard let bytes, bytes > 0 else { return "—" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

private enum EstimatedSizeSeverity {
    case safe
    case warning
    case danger
    case unknown
}

private func estimatedSizeSeverity(for bytes: Int64?, warningBytes: Int64, dangerBytes: Int64) -> EstimatedSizeSeverity {
    guard let bytes, bytes > 0 else { return .unknown }
    if bytes > dangerBytes { return .danger }
    if bytes >= warningBytes { return .warning }
    return .safe
}

func formatSizeThresholdLabel(gigabytes: Double) -> String {
    if gigabytes < 1.0 {
        let mb = (gigabytes * 1024.0).rounded()
        return "\(Int(mb)) MB"
    }
    return String(format: "%.2f GB", gigabytes)
}

struct EstimatedSizePill: View {
    let bytes: Int64?
    let warningThresholdGB: Double
    let dangerThresholdGB: Double

    private var warningBytes: Int64 {
        Int64((warningThresholdGB * 1_073_741_824.0).rounded())
    }

    private var dangerBytes: Int64 {
        Int64((dangerThresholdGB * 1_073_741_824.0).rounded())
    }

    private var accent: Color {
        switch estimatedSizeSeverity(for: bytes, warningBytes: warningBytes, dangerBytes: dangerBytes) {
        case .safe:
            return Color(nsColor: .systemGreen)
        case .warning:
            return Color(nsColor: .systemYellow)
        case .danger:
            return Color(nsColor: .systemRed)
        case .unknown:
            return Color.secondary
        }
    }

    var body: some View {
        Text(formatFileSize(bytes))
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(0.16))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(accent.opacity(0.45), lineWidth: 0.7)
            )
    }
}

func estimateFileSizeBytes(
    durationSeconds: Double,
    totalBitrateKbps: Double,
    overheadFactor: Double = 1.02
) -> Int64? {
    guard durationSeconds > 0, totalBitrateKbps > 0 else { return nil }
    let bytes = ((durationSeconds * totalBitrateKbps * 1000.0) / 8.0) * overheadFactor
    guard bytes.isFinite, bytes > 0 else { return nil }
    return Int64(bytes.rounded())
}

func adaptiveContainerFill(
    material: Material,
    fallback: Color,
    reduceTransparency: Bool
) -> AnyShapeStyle {
    reduceTransparency ? AnyShapeStyle(fallback) : AnyShapeStyle(material)
}

func parseTimecode(_ value: String) -> Double? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let parts = trimmed.split(separator: ":")
    guard !parts.isEmpty && parts.count <= 3 else { return nil }

    func parseSeconds(_ token: Substring) -> Double? {
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }

    switch parts.count {
    case 1:
        guard let s = parseSeconds(parts[0]) else { return nil }
        return s
    case 2:
        guard let m = Double(parts[0]), let s = parseSeconds(parts[1]) else { return nil }
        return (m * 60.0) + s
    case 3:
        guard let h = Double(parts[0]), let m = Double(parts[1]), let s = parseSeconds(parts[2]) else { return nil }
        return (h * 3600.0) + (m * 60.0) + s
    default:
        return nil
    }
}

func fourCCString(_ value: FourCharCode) -> String {
    let chars: [CChar] = [
        CChar((value >> 24) & 0xff),
        CChar((value >> 16) & 0xff),
        CChar((value >> 8) & 0xff),
        CChar(value & 0xff),
        0
    ]
    return String(cString: chars)
}

func loadSourceMediaInfo(for url: URL) -> SourceMediaInfo {
    let asset = AVAsset(url: url)
    var info = SourceMediaInfo()

    let duration = CMTimeGetSeconds(asset.duration)
    if duration.isFinite && duration > 0 {
        info.durationSeconds = duration
    }

    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       let fileSize = attrs[.size] as? NSNumber {
        info.fileSizeBytes = fileSize.int64Value
    }

    let metadataFormats = asset.availableMetadataFormats
    if metadataFormats.contains(.quickTimeMetadata) {
        info.containerDescription = "QuickTime / ISO BMFF"
    } else if metadataFormats.contains(.iTunesMetadata) {
        info.containerDescription = "MPEG-4"
    }

    if let videoTrack = asset.tracks(withMediaType: .video).first {
        let size = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let width = Int(abs(size.width).rounded())
        let height = Int(abs(size.height).rounded())
        if width > 0 && height > 0 {
            info.resolution = "\(width) × \(height)"
        }

        let fps = Double(videoTrack.nominalFrameRate)
        if fps > 0 {
            info.frameRate = fps
        }

        let vBitrate = videoTrack.estimatedDataRate
        if vBitrate > 0 {
            info.videoBitrateBps = Double(vBitrate)
        }

        if let formatDesc = videoTrack.formatDescriptions.first {
            let desc = formatDesc as! CMFormatDescription
            let subtype = CMFormatDescriptionGetMediaSubType(desc)
            let codec = fourCCString(subtype).trimmingCharacters(in: .whitespacesAndNewlines)
            if !codec.isEmpty {
                info.videoCodec = codec
            }

            if let ext = CMFormatDescriptionGetExtensions(desc) as? [CFString: Any] {
                if let primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries] as? String {
                    info.colorPrimaries = primaries
                }
                if let transfer = ext[kCMFormatDescriptionExtension_TransferFunction] as? String {
                    info.colorTransfer = transfer
                }
            }
        }
    }

    if let audioTrack = asset.tracks(withMediaType: .audio).first {
        let aBitrate = audioTrack.estimatedDataRate
        if aBitrate > 0 {
            info.audioBitrateBps = Double(aBitrate)
        }

        if let formatDesc = audioTrack.formatDescriptions.first {
            let desc = formatDesc as! CMAudioFormatDescription
            let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
            if let asbdPtr {
                info.sampleRateHz = asbdPtr.pointee.mSampleRate
                info.channels = Int(asbdPtr.pointee.mChannelsPerFrame)
            }
            let subtype = CMFormatDescriptionGetMediaSubType(desc)
            let codec = fourCCString(subtype).trimmingCharacters(in: .whitespacesAndNewlines)
            if !codec.isEmpty {
                info.audioCodec = codec
            }
        }
    }

    if let fileSize = info.fileSizeBytes, let duration = info.durationSeconds, duration > 0 {
        info.overallBitrateBps = (Double(fileSize) * 8.0) / duration
    }

    return info
}

func generateWaveformSamples(for url: URL, sampleCount: Int) -> [Double] {
    guard sampleCount > 0 else { return [] }

    let asset = AVURLAsset(url: url)
    guard let audioTrack = asset.tracks(withMediaType: .audio).first else { return [] }

    let durationSeconds = CMTimeGetSeconds(asset.duration)
    guard durationSeconds.isFinite && durationSeconds > 0 else { return [] }

    let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false

    let reader: AVAssetReader
    do {
        reader = try AVAssetReader(asset: asset)
    } catch {
        return []
    }
    guard reader.canAdd(output) else { return [] }
    reader.add(output)
    guard reader.startReading() else { return [] }

    var peaks = Array(repeating: 0.0, count: sampleCount)

    while let sampleBuffer = output.copyNextSampleBuffer() {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate > 0 else {
            continue
        }

        let startTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if !startTime.isFinite { continue }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer, length > 0 else { continue }

        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let bytesPerFrame = max(Int(asbd.mBytesPerFrame), channels * 2)
        let frameCount = length / bytesPerFrame
        if frameCount <= 0 { continue }

        let int16Pointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Int16.self)

        for frame in 0..<frameCount {
            let sampleTime = startTime + (Double(frame) / asbd.mSampleRate)
            let bucketFloat = (sampleTime / durationSeconds) * Double(sampleCount - 1)
            let bucket = min(sampleCount - 1, max(0, Int(bucketFloat)))

            var framePeak = 0.0
            for channel in 0..<channels {
                let sampleIndex = frame * channels + channel
                let v = Double(abs(Int(int16Pointer[sampleIndex]))) / Double(Int16.max)
                framePeak = max(framePeak, v)
            }
            peaks[bucket] = max(peaks[bucket], framePeak)
        }
    }

    let maxPeak = peaks.max() ?? 0
    if maxPeak > 0 {
        return peaks.map { $0 / maxPeak }
    }
    return peaks
}

func isFrameMostlyBlack(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
        return false
    }

    CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
        return false
    }

    let width = CVPixelBufferGetWidth(imageBuffer)
    let height = CVPixelBufferGetHeight(imageBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
    if width <= 0 || height <= 0 { return false }

    let xStep = max(1, width / maxSampleDimension)
    let yStep = max(1, height / maxSampleDimension)
    let threshold = 255.0 * pixelBlackThreshold

    let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
    var sampledPixels = 0
    var darkPixels = 0

    var y = 0
    while y < height {
        let row = buffer.advanced(by: y * bytesPerRow)
        var x = 0
        while x < width {
            let pixel = row.advanced(by: x * 4)
            let b = Double(pixel[0])
            let g = Double(pixel[1])
            let r = Double(pixel[2])
            let luma = (0.114 * b) + (0.587 * g) + (0.299 * r)
            if luma <= threshold {
                darkPixels += 1
            }
            sampledPixels += 1
            x += xStep
        }
        y += yStep
    }

    guard sampledPixels > 0 else { return false }
    return (Double(darkPixels) / Double(sampledPixels)) >= picThreshold
}

func buildSegments(blackIntervals: [(start: Double, end: Double)], minDuration: Double) -> [Segment] {
    blackIntervals.compactMap { interval in
        let duration = max(0, interval.end - interval.start)
        guard duration >= minDuration else { return nil }
        return Segment(start: interval.start, end: interval.end, duration: duration)
    }
}

func runDetection(
    file: URL,
    detectBlackFrames: Bool,
    detectAudioSilence: Bool,
    detectProfanity: Bool,
    profanityWords: Set<String> = defaultProfanityWords,
    cachedTranscriptSegments: [TranscriptSegment]? = nil,
    silenceMinDuration: Double = defaultMinSilenceDurationSeconds,
    onStatusUpdate: @escaping @Sendable (String) -> Void = { _ in },
    onBlackSegmentDetected: @escaping @Sendable (Segment) -> Void = { _ in },
    onSilentSegmentDetected: @escaping @Sendable (Segment) -> Void = { _ in },
    onProfanityDetected: @escaping @Sendable (ProfanityHit) -> Void = { _ in },
    onConsoleOutput: @escaping @Sendable (String, String) -> Void = { _, _ in },
    progressHandler: @escaping @Sendable (Double) -> Void = { _ in },
    shouldCancel: @escaping @Sendable () -> Bool = { false }
) -> Result<DetectionOutput, DetectionError> {
    let asset = AVAsset(url: file)

    var intervals: [(start: Double, end: Double)] = []
    var lastTimestamp = 0.0

    let mediaDuration = CMTimeGetSeconds(asset.duration)
    let safeDuration = mediaDuration.isFinite && mediaDuration > 0 ? mediaDuration : nil

    if detectBlackFrames {
        onStatusUpdate("Scanning video for black frames")
        guard let track = asset.tracks(withMediaType: .video).first else {
            return .failure(.failed("No video track found"))
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            return .failure(.failed("Failed to create asset reader: \(error.localizedDescription)"))
        }

        if reader.canAdd(output) {
            reader.add(output)
        } else {
            return .failure(.failed("Unable to configure video reader output"))
        }

        if !reader.startReading() {
            let reason = reader.error?.localizedDescription ?? "Unknown reader error"
            return .failure(.failed("Failed to start reading: \(reason)"))
        }

        var inBlack = false
        var currentStart = 0.0

        var estimatedFrameDuration = CMTimeGetSeconds(track.minFrameDuration)
        if !estimatedFrameDuration.isFinite || estimatedFrameDuration <= 0 {
            estimatedFrameDuration = 1.0 / max(track.nominalFrameRate > 0 ? Double(track.nominalFrameRate) : 30.0, 1.0)
        }

        while let sample = output.copyNextSampleBuffer() {
            if shouldCancel() {
                return .failure(.cancelled)
            }

            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            var frameDuration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
            if !frameDuration.isFinite || frameDuration <= 0 {
                frameDuration = estimatedFrameDuration
            }

            let frameEnd = pts + frameDuration
            lastTimestamp = max(lastTimestamp, frameEnd)

            if let safeDuration {
                let phaseProgress = min(1.0, max(0, frameEnd / safeDuration))
                let mappedProgress = detectAudioSilence ? (phaseProgress * 0.7) : phaseProgress
                progressHandler(min(0.99, mappedProgress))
            }

            if isFrameMostlyBlack(sample) {
                if !inBlack {
                    inBlack = true
                    currentStart = pts
                }
            } else if inBlack {
                intervals.append((start: currentStart, end: pts))
                let duration = max(0, pts - currentStart)
                if duration >= minDurationSeconds {
                    onBlackSegmentDetected(Segment(start: currentStart, end: pts, duration: duration))
                }
                inBlack = false
            }
        }

        if inBlack {
            intervals.append((start: currentStart, end: lastTimestamp))
            let duration = max(0, lastTimestamp - currentStart)
            if duration >= minDurationSeconds {
                onBlackSegmentDetected(Segment(start: currentStart, end: lastTimestamp, duration: duration))
            }
        }

        if reader.status == .failed {
            let reason = reader.error?.localizedDescription ?? "Unknown reader failure"
            return .failure(.failed("Reader failed: \(reason)"))
        }
    }

    let outputDuration = mediaDuration.isFinite && mediaDuration > 0 ? mediaDuration : (lastTimestamp > 0 ? lastTimestamp : nil)
    let segments = detectBlackFrames ? buildSegments(blackIntervals: intervals, minDuration: minDurationSeconds) : []
    var silentSegments: [Segment] = []
    var profanityHits: [ProfanityHit] = []
    var transcriptSegmentsForProfanity: [TranscriptSegment]? = nil

    if detectAudioSilence {
        onStatusUpdate("Analyzing audio for silent gaps")
        let audioResult = detectAudioSilenceSegments(
            file: file,
            minDuration: silenceMinDuration,
            amplitudeThreshold: silenceAmplitudeThreshold,
            onSegmentDetected: { segment in
                onSilentSegmentDetected(segment)
            }
        ) { audioProgress in
            let clamped = min(1, max(0, audioProgress))
            progressHandler(min(0.99, 0.7 + (clamped * 0.3)))
        } shouldCancel: {
            shouldCancel()
        }

        switch audioResult {
        case .success(let detected):
            silentSegments = detected
        case .failure(let error):
            return .failure(error)
        }
    }

    if detectProfanity {
        let usingCachedTranscript = (cachedTranscriptSegments != nil)
        onStatusUpdate(usingCachedTranscript ? "Scanning transcript for profanity" : "Transcribing audio for profanity")
        let profanityBase = (detectAudioSilence || detectBlackFrames) ? 0.70 : 0.0
        let profanitySpan = (detectAudioSilence || detectBlackFrames) ? 0.29 : 0.99
        if let cachedTranscriptSegments {
            transcriptSegmentsForProfanity = cachedTranscriptSegments
            profanityHits = detectProfanityHits(in: cachedTranscriptSegments, profanityWords: profanityWords)
            profanityHits.forEach { onProfanityDetected($0) }
            progressHandler(min(0.99, profanityBase + profanitySpan))
        } else {
            let transcriptResult = transcribeAudioWithWhisper(
                file: file,
                shouldCancel: {
                    shouldCancel()
                },
                progressHandler: { profanityProgress in
                    let clamped = min(1, max(0, profanityProgress))
                    progressHandler(min(0.99, profanityBase + (clamped * profanitySpan)))
                },
                onConsoleOutput: onConsoleOutput
            )
            switch transcriptResult {
            case .success(let transcriptSegments):
                transcriptSegmentsForProfanity = transcriptSegments
                profanityHits = detectProfanityHits(in: transcriptSegments, profanityWords: profanityWords)
                profanityHits.forEach { onProfanityDetected($0) }
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    progressHandler(1.0)
    return .success(DetectionOutput(
        segments: segments,
        silentSegments: silentSegments,
        profanityHits: profanityHits,
        transcriptSegments: transcriptSegmentsForProfanity,
        mediaDuration: outputDuration
    ))
}

func detectAudioSilenceSegments(
    file: URL,
    minDuration: Double,
    amplitudeThreshold: Double,
    onSegmentDetected: @escaping @Sendable (Segment) -> Void = { _ in },
    progressHandler: @escaping @Sendable (Double) -> Void = { _ in },
    shouldCancel: @escaping @Sendable () -> Bool = { false }
) -> Result<[Segment], DetectionError> {
    let asset = AVURLAsset(url: file)
    guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
        return .success([])
    }

    let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false

    let reader: AVAssetReader
    do {
        reader = try AVAssetReader(asset: asset)
    } catch {
        return .failure(.failed("Failed to create audio reader: \(error.localizedDescription)"))
    }

    guard reader.canAdd(output) else {
        return .failure(.failed("Unable to configure audio reader output"))
    }
    reader.add(output)

    guard reader.startReading() else {
        let reason = reader.error?.localizedDescription ?? "Unknown audio reader error"
        return .failure(.failed("Failed to start audio reading: \(reason)"))
    }

    let mediaDuration = CMTimeGetSeconds(asset.duration)
    let safeDuration = mediaDuration.isFinite && mediaDuration > 0 ? mediaDuration : nil

    var intervals: [(start: Double, end: Double)] = []
    var inSilence = false
    var currentStart = 0.0
    var lastTimestamp = 0.0

    while let sampleBuffer = output.copyNextSampleBuffer() {
        if shouldCancel() {
            return .failure(.cancelled)
        }

        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate > 0 else {
            continue
        }

        let startTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if !startTime.isFinite { continue }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer, length > 0 else { continue }

        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let bytesPerFrame = max(Int(asbd.mBytesPerFrame), channels * 2)
        let frameCount = length / bytesPerFrame
        if frameCount <= 0 { continue }

        let int16Pointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Int16.self)
        let frameStep = 1.0 / asbd.mSampleRate

        for frame in 0..<frameCount {
            let sampleTime = startTime + (Double(frame) * frameStep)
            let sampleEnd = sampleTime + frameStep
            lastTimestamp = max(lastTimestamp, sampleEnd)

            var peak = 0.0
            for channel in 0..<channels {
                let sampleIndex = frame * channels + channel
                let v = Double(abs(Int(int16Pointer[sampleIndex]))) / Double(Int16.max)
                peak = max(peak, v)
            }

            if peak <= amplitudeThreshold {
                if !inSilence {
                    inSilence = true
                    currentStart = sampleTime
                }
            } else if inSilence {
                intervals.append((start: currentStart, end: sampleTime))
                let duration = max(0, sampleTime - currentStart)
                if duration >= minDuration {
                    onSegmentDetected(Segment(start: currentStart, end: sampleTime, duration: duration))
                }
                inSilence = false
            }
        }

        if let safeDuration {
            progressHandler(min(0.99, max(0, lastTimestamp / safeDuration)))
        }
    }

    if inSilence {
        intervals.append((start: currentStart, end: lastTimestamp))
        let duration = max(0, lastTimestamp - currentStart)
        if duration >= minDuration {
            onSegmentDetected(Segment(start: currentStart, end: lastTimestamp, duration: duration))
        }
    }

    if reader.status == .failed {
        let reason = reader.error?.localizedDescription ?? "Unknown audio reader failure"
        return .failure(.failed("Audio reader failed: \(reason)"))
    }

    progressHandler(1.0)
    return .success(buildSegments(blackIntervals: intervals, minDuration: minDuration))
}

func normalizedToken(_ token: String) -> String {
    token
        .trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines))
        .lowercased()
}

func profanityWordsFromString(_ raw: String) -> Set<String> {
    let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
    return Set(
        raw.components(separatedBy: separators)
            .map(normalizedToken)
            .filter { !$0.isEmpty }
    )
}

func normalizedProfanityWordsStorageString(_ raw: String) -> String {
    profanityWordsFromString(raw).sorted().joined(separator: ", ")
}

func sanitizeFilenameComponent(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
    let sanitizedScalars = value.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) }
    let sanitized = String(sanitizedScalars)
        .replacingOccurrences(of: "\n", with: "_")
        .replacingOccurrences(of: "\r", with: "_")
    return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
}

func extractPercentProgress(from line: String) -> Double? {
    let pattern = #"([0-9]{1,3})(?:\.[0-9]+)?\s*%"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    guard let match = regex.firstMatch(in: line, range: range),
          let percentRange = Range(match.range(at: 1), in: line),
          let percent = Double(line[percentRange]) else { return nil }
    return min(max(percent / 100.0, 0.0), 1.0)
}

func findWhisperExecutable() -> URL? {
    if let bundled = Bundle.main.url(forResource: "whisper-cli", withExtension: nil),
       FileManager.default.isExecutableFile(atPath: bundled.path) {
        return bundled
    }
    return nil
}

func findWhisperModel() -> URL? {
    if let bundled = Bundle.main.url(forResource: "profanity-model", withExtension: "bin"),
       FileManager.default.fileExists(atPath: bundled.path) {
        return bundled
    }
    return nil
}

private func findSystemFFmpegExecutable() -> URL? {
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

    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
        return URL(fileURLWithPath: candidate)
    }
    return nil
}

private func runSynchronousProcess(
    executableURL: URL,
    arguments: [String],
    shouldCancel: @escaping @Sendable () -> Bool,
    source: String,
    onOutputLine: @escaping @Sendable (String, String) -> Void = { _, _ in }
) -> Result<(stdout: String, stderr: String), DetectionError> {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    onOutputLine("$ \(executableURL.path) " + arguments.joined(separator: " "), source)

    var stdoutData = Data()
    var stderrData = Data()
    let lock = NSLock()

    func emitLines(_ data: Data, sourceTag: String) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                onOutputLine(line, sourceTag)
            }
        }
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock()
        stdoutData.append(chunk)
        lock.unlock()
        emitLines(chunk, sourceTag: source)
    }

    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock()
        stderrData.append(chunk)
        lock.unlock()
        emitLines(chunk, sourceTag: source)
    }

    do {
        try process.run()
    } catch {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return .failure(.failed("Failed to run \(executableURL.lastPathComponent): \(error.localizedDescription)"))
    }

    while process.isRunning {
        if shouldCancel() {
            process.terminate()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(.cancelled)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    lock.lock()
    let trailingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let trailingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    stdoutData.append(trailingStdout)
    stderrData.append(trailingStderr)
    let stdout = String(decoding: stdoutData, as: UTF8.self)
    let stderr = String(decoding: stderrData, as: UTF8.self)
    lock.unlock()
    emitLines(trailingStdout, sourceTag: source)
    emitLines(trailingStderr, sourceTag: source)

    if process.terminationStatus == 0 {
        return .success((stdout: stdout, stderr: stderr))
    }

    let errorText = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if errorText.isEmpty {
        return .failure(.failed("\(executableURL.lastPathComponent) exited with status \(process.terminationStatus)"))
    }
    return .failure(.failed(errorText))
}

private func runSynchronousProcessWithProgress(
    executableURL: URL,
    arguments: [String],
    shouldCancel: @escaping @Sendable () -> Bool,
    progressHandler: @escaping @Sendable (Double) -> Void,
    source: String,
    onOutputLine: @escaping @Sendable (String, String) -> Void = { _, _ in }
) -> Result<(stdout: String, stderr: String), DetectionError> {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    onOutputLine("$ \(executableURL.path) " + arguments.joined(separator: " "), source)

    var stdoutData = Data()
    var stderrData = Data()
    let lock = NSLock()

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        if let text = String(data: data, encoding: .utf8) {
            for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                onOutputLine(line, source)
                if let progress = extractPercentProgress(from: line) {
                    progressHandler(progress)
                }
            }
        }
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock()
        stdoutData.append(chunk)
        lock.unlock()
        consume(chunk)
    }

    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock()
        stderrData.append(chunk)
        lock.unlock()
        consume(chunk)
    }

    do {
        try process.run()
    } catch {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return .failure(.failed("Failed to run \(executableURL.lastPathComponent): \(error.localizedDescription)"))
    }

    while process.isRunning {
        if shouldCancel() {
            process.terminate()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(.cancelled)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    lock.lock()
    let trailingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let trailingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    stdoutData.append(trailingStdout)
    stderrData.append(trailingStderr)
    let stdout = String(decoding: stdoutData, as: UTF8.self)
    let stderr = String(decoding: stderrData, as: UTF8.self)
    lock.unlock()

    if process.terminationStatus == 0 {
        progressHandler(1.0)
        return .success((stdout: stdout, stderr: stderr))
    }

    let errorText = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if errorText.isEmpty {
        return .failure(.failed("\(executableURL.lastPathComponent) exited with status \(process.terminationStatus)"))
    }
    return .failure(.failed(errorText))
}

private func parseTranscriptionSegments(_ jsonData: Data) -> [TranscriptSegment] {
    guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        return []
    }

    var segmentsOut: [TranscriptSegment] = []
    let transcription = object["transcription"] as? [[String: Any]] ?? object["segments"] as? [[String: Any]] ?? []
    for segment in transcription {
        let text = (segment["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }

        let startMs: Double? = ((segment["offsets"] as? [String: Any])?["from"] as? Double)
        let endMs: Double? = ((segment["offsets"] as? [String: Any])?["to"] as? Double)
        let startSecAlt = segment["start"] as? Double
        let endSecAlt = segment["end"] as? Double

        let start = max(0, (startMs ?? (startSecAlt ?? 0)) / (startMs != nil ? 1000.0 : 1.0))
        let endRaw = (endMs ?? (endSecAlt ?? (start + 0.2))) / (endMs != nil ? 1000.0 : 1.0)
        let end = max(start + 0.05, endRaw)
        segmentsOut.append(TranscriptSegment(start: start, end: end, text: text))
    }

    segmentsOut.sort { lhs, rhs in
        if abs(lhs.start - rhs.start) > 0.0001 { return lhs.start < rhs.start }
        return lhs.text < rhs.text
    }
    return segmentsOut
}

private func detectProfanityHits(
    in transcriptSegments: [TranscriptSegment],
    profanityWords: Set<String>
) -> [ProfanityHit] {
    var hits: [ProfanityHit] = []
    for segment in transcriptSegments {
        let tokens = segment.text.split(whereSeparator: { $0.isWhitespace }).map { normalizedToken(String($0)) }
        let matchedWords = tokens.filter { profanityWords.contains($0) }
        if matchedWords.isEmpty { continue }
        let duration = segment.duration
        for word in matchedWords {
            hits.append(ProfanityHit(start: segment.start, end: segment.end, duration: duration, word: word))
        }
    }
    hits.sort { lhs, rhs in
        if abs(lhs.start - rhs.start) > 0.0001 { return lhs.start < rhs.start }
        return lhs.word < rhs.word
    }
    return hits
}

func transcribeAudioWithWhisper(
    file: URL,
    shouldCancel: @escaping @Sendable () -> Bool = { false },
    progressHandler: @escaping @Sendable (Double) -> Void = { _ in },
    onConsoleOutput: @escaping @Sendable (String, String) -> Void = { _, _ in }
) -> Result<[TranscriptSegment], DetectionError> {
    if shouldCancel() {
        return .failure(.cancelled)
    }

    guard let ffmpegURL = findSystemFFmpegExecutable() else {
        return .failure(.failed("No ffmpeg executable found for Whisper transcription."))
    }
    guard let whisperURL = findWhisperExecutable() else {
        return .failure(.failed("Bundled whisper-cli not found (Contents/Resources/whisper-cli)."))
    }
    guard let modelURL = findWhisperModel() else {
        return .failure(.failed("Bundled Whisper model not found (Contents/Resources/profanity-model.bin)."))
    }

    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("bvt-whisper-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    } catch {
        return .failure(.failed("Failed to create temp directory: \(error.localizedDescription)"))
    }
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let wavURL = tempRoot.appendingPathComponent("audio.wav")
    let outputPrefix = tempRoot.appendingPathComponent("transcript")
    let outputJSON = tempRoot.appendingPathComponent("transcript.json")

    let ffmpegResult = runSynchronousProcess(
        executableURL: ffmpegURL,
        arguments: [
            "-y",
            "-hide_banner",
            "-loglevel", "error",
            "-i", file.path,
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-f", "wav",
            wavURL.path
        ],
        shouldCancel: shouldCancel,
        source: "ffmpeg",
        onOutputLine: onConsoleOutput
    )
    switch ffmpegResult {
    case .failure(let error):
        return .failure(error)
    case .success:
        break
    }

    let whisperResult = runSynchronousProcessWithProgress(
        executableURL: whisperURL,
        arguments: [
            "-m", modelURL.path,
            "-f", wavURL.path,
            "-of", outputPrefix.path,
            "-oj",
            "-pp"
        ],
        shouldCancel: shouldCancel,
        progressHandler: progressHandler,
        source: "whisper",
        onOutputLine: onConsoleOutput
    )
    switch whisperResult {
    case .success:
        break
    case .failure(.cancelled):
        return .failure(.cancelled)
    case .failure(.failed(let reason)):
        let cpuRetry = runSynchronousProcessWithProgress(
            executableURL: whisperURL,
            arguments: [
                "-ng",
                "-nfa",
                "-m", modelURL.path,
                "-f", wavURL.path,
                "-of", outputPrefix.path,
                "-oj",
                "-pp"
            ],
            shouldCancel: shouldCancel,
            progressHandler: progressHandler,
            source: "whisper",
            onOutputLine: onConsoleOutput
        )

        switch cpuRetry {
        case .success:
            break
        case .failure(.cancelled):
            return .failure(.cancelled)
        case .failure(.failed(let retryReason)):
            return .failure(.failed("Whisper transcription failed: \(retryReason). Initial error: \(reason)."))
        }
    }

    guard let jsonData = try? Data(contentsOf: outputJSON) else {
        return .failure(.failed("Whisper did not produce transcript JSON output."))
    }

    return .success(parseTranscriptionSegments(jsonData))
}

func detectProfanityHits(
    file: URL,
    profanityWords: Set<String>,
    cachedTranscriptSegments: [TranscriptSegment]? = nil,
    shouldCancel: @escaping @Sendable () -> Bool = { false },
    progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
) -> Result<[ProfanityHit], DetectionError> {
    if let cachedTranscriptSegments {
        progressHandler(1.0)
        return .success(detectProfanityHits(in: cachedTranscriptSegments, profanityWords: profanityWords))
    }

    let transcriptResult = transcribeAudioWithWhisper(
        file: file,
        shouldCancel: shouldCancel,
        progressHandler: progressHandler
    )
    switch transcriptResult {
    case .failure(let error):
        return .failure(error)
    case .success(let transcriptSegments):
        return .success(detectProfanityHits(in: transcriptSegments, profanityWords: profanityWords))
    }
}

func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

@MainActor
final class ExternalFileOpenBridge: ObservableObject {
    static let shared = ExternalFileOpenBridge()
    @Published var incomingURL: URL?

    private init() {}

    func open(_ url: URL) {
        incomingURL = url
    }
}

@MainActor
final class DockProgressController {
    static let shared = DockProgressController()

    private var rootView: NSView?
    private var iconView: NSImageView?
    private var trackView: NSView?
    private var fillView: NSView?
    private var active = false

    private init() {}

    private func ensureViewHierarchy() {
        guard rootView == nil else { return }

        let size = NSSize(width: 128, height: 128)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true

        let icon = NSImageView(frame: root.bounds)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.autoresizingMask = [.width, .height]
        root.addSubview(icon)

        let trackHeight: CGFloat = 10
        let horizontalInset: CGFloat = 14
        let bottomInset: CGFloat = 10
        let trackFrame = NSRect(
            x: horizontalInset,
            y: bottomInset,
            width: size.width - (horizontalInset * 2),
            height: trackHeight
        )

        let track = NSView(frame: trackFrame)
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        track.layer?.cornerRadius = trackHeight / 2
        track.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        track.layer?.borderWidth = 0.7
        track.autoresizingMask = [.width, .minYMargin]

        let fill = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: trackHeight))
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        fill.layer?.cornerRadius = trackHeight / 2
        fill.autoresizingMask = [.height]
        track.addSubview(fill)

        root.addSubview(track)

        rootView = root
        iconView = icon
        trackView = track
        fillView = fill
    }

    func setProgress(_ progress: Double) {
        ensureViewHierarchy()

        let clamped = min(max(progress, 0), 1)
        guard let rootView, let iconView, let trackView, let fillView else { return }

        iconView.image = NSApp.applicationIconImage
        let width = max(2, trackView.bounds.width * CGFloat(clamped))
        fillView.frame = NSRect(x: 0, y: 0, width: width, height: trackView.bounds.height)

        if !active {
            NSApp.dockTile.contentView = rootView
            active = true
        }
        NSApp.dockTile.display()
    }

    func clear() {
        guard active else { return }
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
        active = false
    }
}

struct SourceHeaderView: View {
    @ObservedObject var model: WorkspaceViewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private func fileIcon(for url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(model.sourceURL == nil ? "Choose Media" : "Change Media") {
                model.chooseSource()
            }

            Spacer()

            if let sourceURL = model.sourceURL {
                HStack(spacing: 6) {
                    Image(nsImage: fileIcon(for: sourceURL))
                        .interpolation(.high)
                    Text(sourceURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    adaptiveContainerFill(
                        material: .thinMaterial,
                        fallback: Color(nsColor: .controlBackgroundColor),
                        reduceTransparency: reduceTransparency
                    ),
                    in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.45)
                )
                .help(sourceURL.path)
                .onDrag {
                    NSItemProvider(contentsOf: sourceURL) ?? NSItemProvider()
                }
                .contextMenu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sourceURL.path, forType: .string)
                    }
                }
            }
        }
        .padding(12)
        .background(
            adaptiveContainerFill(
                material: .regularMaterial,
                fallback: Color(nsColor: .windowBackgroundColor),
                reduceTransparency: reduceTransparency
            ),
            in: RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
    }
}

struct ToolContentView: View {
    @ObservedObject var model: WorkspaceViewModel
    let isCompactLayout: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        TabView(selection: $model.selectedTool) {
            ScrollView {
                ClipToolView(model: model, isCompactLayout: isCompactLayout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("clip-\(model.sourceSessionID.uuidString)")
            }
            .padding(10)
            .scrollIndicators(.automatic)
            .tabItem { Text(WorkspaceTool.clip.rawValue) }
            .tag(WorkspaceTool.clip)

            ScrollView {
                AnalyzeToolView(model: model, isCompactLayout: isCompactLayout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("analyze-\(model.sourceSessionID.uuidString)")
            }
            .padding(10)
            .scrollIndicators(.automatic)
            .tabItem { Text(WorkspaceTool.analyze.rawValue) }
            .tag(WorkspaceTool.analyze)

            ScrollView {
                ConvertToolView(model: model, isCompactLayout: isCompactLayout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("convert-\(model.sourceSessionID.uuidString)")
            }
            .padding(10)
            .scrollIndicators(.automatic)
            .tabItem { Text(WorkspaceTool.convert.rawValue) }
            .tag(WorkspaceTool.convert)

            ScrollView {
                InspectToolView(
                    sourceURL: model.sourceURL,
                    analysis: model.analysis,
                    sourceInfo: model.sourceInfo,
                    transcriptSegments: model.transcriptSegments,
                    transcriptStatusText: model.transcriptStatusText,
                    canGenerateTranscript: model.canGenerateTranscript,
                    isGeneratingTranscript: model.isGeneratingTranscript,
                    whisperTranscriptionAvailable: model.whisperTranscriptionAvailable,
                    hasAudioTrack: model.hasAudioTrack,
                    generateTranscript: { model.generateTranscriptFromInspect() },
                    exportTranscriptTXT: { model.exportTranscriptTXTFromInspect() },
                    isCompactLayout: isCompactLayout
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("inspect-\(model.sourceSessionID.uuidString)")
            }
            .padding(10)
            .scrollIndicators(.automatic)
            .tabItem { Text(WorkspaceTool.inspect.rawValue) }
            .tag(WorkspaceTool.inspect)
        }
        .background(
            adaptiveContainerFill(
                material: .regularMaterial,
                fallback: Color(nsColor: .windowBackgroundColor),
                reduceTransparency: reduceTransparency
            ),
            in: RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
    }
}

struct AnalyzeToolView: View {
    @ObservedObject var model: WorkspaceViewModel
    let isCompactLayout: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var blackFrameToggleBinding: Binding<Bool> {
        Binding(
            get: { model.hasVideoTrack ? model.analyzeBlackFrames : false },
            set: { model.analyzeBlackFrames = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.sourceURL != nil {
                HStack(spacing: 8) {
                    Button {
                        model.startAnalysis()
                    } label: {
                        Label(model.isAnalyzing ? "Analyzing…" : "Run Analysis", systemImage: "waveform.path.ecg")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canAnalyze)

                    if model.isAnalyzing {
                        Button {
                            model.stopAnalysis()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Toggle("Detect black frames", isOn: blackFrameToggleBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.isAnalyzing || !model.hasVideoTrack)

                Toggle("Detect silent audio gaps (over \(model.silenceMinDurationLabel)s)", isOn: $model.analyzeAudioSilence)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.isAnalyzing || !model.hasAudioTrack)

                Toggle("Detect profanity (Whisper transcription)", isOn: $model.analyzeProfanity)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.isAnalyzing || !model.hasAudioTrack)

                if let analysis = model.analysis {
                    Text(analysis.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Group {
                    if let analysis = model.analysis {
                        DetailView(file: analysis, isCompactLayout: isCompactLayout, model: model)
                    } else {
                        Text("Ready to analyze")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            } else {
                EmptyToolView(title: "Analyze", subtitle: "Choose media and run analysis.")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.sourceURL != nil)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.analysis?.summary ?? "")
    }
}

struct ConvertToolView: View {
    @ObservedObject var model: WorkspaceViewModel
    let isCompactLayout: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.sourceURL != nil {
                Group {
                    GroupBox("Audio Export") {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 8) {
                                Picker("Format", selection: $model.selectedAudioFormat) {
                                    ForEach(AudioFormat.allCases) { format in
                                        Text(format.rawValue).tag(format)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .controlSize(.small)

                                HStack {
                                    Text("Bitrate (MP3)")
                                    Slider(value: Binding(
                                        get: { Double(model.exportAudioBitrateKbps) },
                                        set: { model.exportAudioBitrateKbps = Int($0.rounded()) }
                                    ), in: 96...320, step: 32)
                                    .controlSize(.small)
                                    Text("\(model.exportAudioBitrateKbps) kbps")
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 90, alignment: .trailing)
                                }

                                Text("M4A uses native AVFoundation export. MP3 uses ffmpeg and defaults to 128 kbps.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            Divider()

                            HStack {
                                if model.selectedAudioFormat == .mp3 {
                                    HStack(spacing: 8) {
                                        Label("Estimated output size", systemImage: "ruler")
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.tertiary)
                                        EstimatedSizePill(
                                            bytes: model.estimatedAudioExportSizeBytes,
                                            warningThresholdGB: model.estimatedSizeWarningThresholdGB,
                                            dangerThresholdGB: model.estimatedSizeDangerThresholdGB
                                        )
                                    }
                                }
                                Spacer(minLength: 8)
                                Button {
                                    model.startExport()
                                } label: {
                                    Label(model.isExporting ? "Exporting…" : "Export Audio", systemImage: "arrow.down.doc")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.canExport)
                            }
                        }
                        .padding(10)
                        .background(
                            adaptiveContainerFill(
                                material: .thinMaterial,
                                fallback: Color(nsColor: .controlBackgroundColor),
                                reduceTransparency: reduceTransparency
                            ),
                            in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                .stroke(Color.primary.opacity(0.045), lineWidth: 0.4)
                        )
                    }

                    if let source = model.sourceURL {
                        Text("Source: \(source.path)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            } else {
                EmptyToolView(title: "Convert", subtitle: "Choose source media to enable audio export.")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.sourceURL != nil)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.isExporting)
    }
}

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
    @State private var playheadCopyFlash = false
    @State private var timelinePointerSeconds: Double?
    @State private var clipWindow: NSWindow?
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

    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
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

    private func loadPlayerItem() {
        guard let sourceURL = model.sourceURL else {
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
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playheadSeconds = clamped
        model.clipPlayheadSeconds = clamped
        model.selectTimelineMarkerIfAligned(near: clamped)
        syncVisualPlayheadImmediately(clamped)
        updateViewportForPlayhead(shouldFollow: !isViewportManuallyControlled || player.rate != 0)
    }

    private func seekPlayerInteractive(to time: Double) {
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
        model.clipPlayheadSeconds = clamped
        model.selectTimelineMarkerIfAligned(near: clamped)
        syncVisualPlayheadImmediately(clamped)
        updateViewportForPlayhead(shouldFollow: false)
    }

    private func seekPlayerAndFocusViewport(to time: Double, focusViewport: Bool = true) {
        let clamped = max(0, min(time, max(playerDurationSeconds, model.sourceDurationSeconds)))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playheadSeconds = clamped
        model.clipPlayheadSeconds = clamped
        model.selectTimelineMarkerIfAligned(near: clamped)

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
            viewportStartSeconds = 0
            isViewportManuallyControlled = false
            return
        }

        let window = zoomedWindowDuration
        var start = clampedViewportStart(viewportStartSeconds)
        let end = start + window
        // Always keep the playhead visible, even when follow mode is otherwise disabled.
        if playheadSeconds < start || playheadSeconds > end {
            animateViewportRecenter(to: playheadSeconds - (window / 2))
            return
        }

        guard shouldFollow else {
            viewportStartSeconds = start
            return
        }

        let deadStart = start + deadZonePaddingSeconds
        let deadEnd = end - deadZonePaddingSeconds
        if playheadSeconds < deadStart {
            start = playheadSeconds - deadZonePaddingSeconds
        } else if playheadSeconds > deadEnd {
            start = playheadSeconds - (window - deadZonePaddingSeconds)
        }
        viewportStartSeconds = clampedViewportStart(start)
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
            startPlayheadDragAutoPanLoopIfNeeded()
        } else {
            stopPlayheadDragAutoPanLoop()
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
            if NSApp.keyWindow?.firstResponder is NSTextView {
                return event
            }

            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let rawChars = event.characters ?? ""
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasDisallowedModifier = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)

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

            if !hasDisallowedModifier && !flags.contains(.shift) {
                if event.specialKey == .home {
                    seekPlayer(to: 0)
                    return nil
                }
                if event.specialKey == .end {
                    seekPlayer(to: totalDurationSeconds)
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
                    model.setClipStart(playheadSeconds, undoManager: undoManager)
                    return nil
                }
                if chars == "o" {
                    model.setClipEnd(playheadSeconds, undoManager: undoManager)
                    return nil
                }
                if chars == "x" {
                    model.resetClipRange(undoManager: undoManager)
                    seekPlayer(to: model.clipStartSeconds)
                    return nil
                }
                if chars == "m" {
                    model.addTimelineMarker(at: playheadSeconds, undoManager: undoManager)
                    return nil
                }
            }

            let hasShift = flags.contains(.shift)
            guard hasShift && !hasDisallowedModifier else { return event }

            let fps = max(1.0, model.sourceInfo?.frameRate ?? 30.0)
            let tenFrames = 10.0 / fps

            if event.specialKey == .leftArrow {
                seekPlayer(to: playheadSeconds - tenFrames)
                return nil
            }

            if event.specialKey == .rightArrow {
                seekPlayer(to: playheadSeconds + tenFrames)
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
            let panPoints: CGFloat
            if abs(dx) >= 0.1 {
                panPoints = dx
            } else if event.modifierFlags.contains(.shift) && abs(dy) >= 0.1 {
                panPoints = dy
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

    private var clipPlayerSection: some View {
        InlinePlayerView(player: player)
            .frame(
                minHeight: isCompactLayout ? 170 : 290,
                maxHeight: isCompactLayout ? 230 : 350
            )
            .clipShape(RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous))
            .onTapGesture {
                dismissTimecodeFieldFocus()
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
            model: model,
            isCompactLayout: isCompactLayout,
            reduceTransparency: reduceTransparency,
            isWaveformLoading: isWaveformLoading,
            waveformSamples: waveformSamples,
            allowedTimelineZoomLevels: allowedTimelineZoomLevels,
            timelineZoom: timelineZoom,
            totalDurationSeconds: totalDurationSeconds,
            visibleStartSeconds: visibleStartSeconds,
            visibleEndSeconds: visibleEndSeconds,
            playheadVisualSeconds: playheadVisualSeconds,
            playheadJumpFromSeconds: playheadJumpFromSeconds,
            playheadJumpAnimationToken: playheadJumpAnimationToken,
            playheadSeconds: playheadSeconds,
            playheadCopyFlash: playheadCopyFlash,
            isTimelineHovered: isTimelineHovered,
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
    }

    private var outputSection: some View {
        ClipOutputPanel(
            model: model,
            reduceTransparency: reduceTransparency,
            isOptionKeyPressed: isOptionKeyPressed,
            fastClipFormats: fastClipFormats,
            advancedClipFormats: advancedClipFormats
        ) { quickExport in
            model.commitClipStartText(undoManager: undoManager)
            model.commitClipEndText(undoManager: undoManager)
            model.startClipExport(skipSaveDialog: quickExport)
        }
    }

    private var clipBaseContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.sourceURL != nil {
                clipPlayerSection
                timelineControlsSection
                outputSection
            } else {
                EmptyToolView(title: "Clip", subtitle: "Choose source media to create a new clip from a selected range.")
            }

            Spacer()
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissTimecodeFieldFocus()
                }
        }
    }

    private func withLifecycleHandlers<V: View>(_ view: V) -> some View {
        let step1 = view.onAppear {
            loadPlayerItem()
            installKeyMonitor()
            installFlagsMonitor()
            installScrollMonitor()
            installMouseDownMonitor()
            installMiddleMousePanMonitor()
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
            .onChange(of: model.selectedClipFormat) { format in
                if format == .webm {
                    model.clipAdvancedVideoCodec = .h264
                }
            }

        let step5 = step4.onReceive(timer) { _ in
            let current = CMTimeGetSeconds(player.currentTime())
            if current.isFinite {
                let newPlayhead = max(0, current)
                let didMove = abs(newPlayhead - playheadSeconds) > (1.0 / 240.0)

                if didMove {
                    playheadSeconds = newPlayhead
                    model.clipPlayheadSeconds = newPlayhead
                    model.selectTimelineMarkerIfAligned(near: newPlayhead)
                    if Date() >= suppressVisualPlayheadSyncUntil {
                        playheadVisualSeconds = newPlayhead
                    }
                }

                if player.rate != 0 {
                    isViewportManuallyControlled = false
                    updateViewportForPlayhead(shouldFollow: true)
                } else if didMove {
                    updateViewportForPlayhead(shouldFollow: false)
                }
            }
            let currentDuration = CMTimeGetSeconds(player.currentItem?.duration ?? .invalid)
            if currentDuration.isFinite && currentDuration > 0 {
                if abs(currentDuration - playerDurationSeconds) > (1.0 / 120.0) {
                    playerDurationSeconds = currentDuration
                }
            }
        }

        let step6 = step5
            .onReceive(NotificationCenter.default.publisher(for: .clipSetStartAtPlayhead, object: model)) { _ in
                model.setClipStart(playheadSeconds, undoManager: undoManager)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipSetEndAtPlayhead, object: model)) { _ in
                model.setClipEnd(playheadSeconds, undoManager: undoManager)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipClearRange, object: model)) { _ in
                model.resetClipRange(undoManager: undoManager)
                seekPlayer(to: model.clipStartSeconds)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipAddMarkerAtPlayhead, object: model)) { _ in
                model.addTimelineMarker(at: playheadSeconds, undoManager: undoManager)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipJumpToStart, object: model)) { _ in
                navigateToMarker(previous: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipJumpToEnd, object: model)) { _ in
                navigateToMarker(previous: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipCaptureFrame, object: model)) { _ in
                model.captureFrame(at: playheadSeconds)
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

        return step6.onDisappear {
            waveformTask?.cancel()
            removeKeyMonitor()
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

struct WaveformView: View {
    @Environment(\.colorScheme) private var colorScheme
    let sourceSessionID: UUID
    let samples: [Double]
    let zoomLevel: Double
    let renderBuckets: [Double]
    let startSeconds: Double
    let visualPlayheadSeconds: Double
    let playheadJumpFromSeconds: Double
    let playheadJumpAnimationToken: Int
    let endSeconds: Double
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let captureMarkers: [CaptureTimelineMarker]
    let highlightedMarkerID: UUID?
    let highlightedClipBoundary: ClipBoundaryHighlight?
    let captureFrameFlashToken: Int
    let quickExportFlashToken: Int
    let onSeek: (Double, Bool) -> Void
    let onPlayheadDragEdgePan: (CGFloat, CGFloat) -> Void
    let onPlayheadDragStateChanged: (Bool) -> Void
    let onSetStart: (Double) -> Void
    let onSetEnd: (Double) -> Void
    let onHoverChanged: (Bool) -> Void
    let onPointerTimeChanged: (Double?) -> Void
    @State private var didStartPlayheadDrag = false
    @State private var isHovered = false
    @State private var isStartEdgeHovered = false
    @State private var isEndEdgeHovered = false
    @State private var isStartEdgeDragging = false
    @State private var isEndEdgeDragging = false
    @State private var startEdgeDragAnchor: Double?
    @State private var endEdgeDragAnchor: Double?
    @State private var isPlayheadCaptureFlashing = false
    @State private var selectionFlashOpacity: Double = 0
    @State private var selectionFlashGlowOpacity: Double = 0
    @State private var isResizeCursorActive = false
    @State private var markerSnapLockSeconds: Double?

    private var visibleDuration: Double {
        max(0.0001, visibleEndSeconds - visibleStartSeconds)
    }

    private func xPosition(for value: Double, width: CGFloat) -> CGFloat {
        let local = value - visibleStartSeconds
        return CGFloat(local / visibleDuration) * width
    }

    private func timeValue(for x: CGFloat, width: CGFloat, windowStart: Double, windowEnd: Double) -> Double {
        guard width > 0 else { return 0 }
        let ratio = min(max(0, x / width), 1.0)
        let duration = max(0.0001, windowEnd - windowStart)
        return min(totalDurationSeconds, max(0, windowStart + (Double(ratio) * duration)))
    }

    private func snapToPixel(_ value: CGFloat) -> CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixel = CGFloat(1.0 / scale)
        return (value / pixel).rounded() * pixel
    }

    private var systemAccent: Color {
        Color(nsColor: .controlAccentColor)
    }

    private func rulerMajorStep(for visibleDuration: Double) -> Double {
        let candidates: [Double] = [
            1.0 / 30.0, 1.0 / 15.0, 0.1, 0.2, 0.5,
            1, 2, 5, 10, 15, 30, 60, 120, 300, 600
        ]
        for step in candidates where (visibleDuration / step) <= 10 {
            return step
        }
        return candidates.last ?? 600
    }

    private func rulerMinorDivisions(for majorStep: Double) -> Int {
        if majorStep >= 60 { return 6 }
        if majorStep >= 1 { return 5 }
        return 2
    }

    private func rulerLabel(for seconds: Double, majorStep: Double) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = whole % 60
        if majorStep < 1 {
            let centiseconds = Int(((clamped - floor(clamped)) * 100).rounded())
            if hours > 0 {
                return String(format: "%d:%02d:%02d.%02d", hours, minutes, secs, centiseconds)
            }
            return String(format: "%02d:%02d.%02d", minutes, secs, centiseconds)
        }
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func makeRulerTicks(
        visibleStart: Double,
        visibleEnd: Double,
        width: CGFloat,
        majorStep: Double,
        minorStep: Double
    ) -> (minor: [CGFloat], major: [(x: CGFloat, seconds: Double)]) {
        let duration = max(0.0001, visibleEnd - visibleStart)
        func xPosition(for value: Double) -> CGFloat {
            let local = value - visibleStart
            return CGFloat(local / duration) * width
        }

        let epsilon = minorStep * 0.001
        var minorTicks: [CGFloat] = []
        var majorTicks: [(x: CGFloat, seconds: Double)] = []
        var t = floor(visibleStart / minorStep) * minorStep
        var guardCount = 0
        while t <= (visibleEnd + minorStep) && guardCount < 10_000 {
            let x = xPosition(for: t)
            if x >= -1 && x <= width + 1 {
                let majorRatio = t / majorStep
                if abs(majorRatio - majorRatio.rounded()) <= epsilon {
                    majorTicks.append((x: x, seconds: t))
                } else {
                    minorTicks.append(x)
                }
            }
            t += minorStep
            guardCount += 1
        }
        return (minorTicks, majorTicks)
    }

    private func filterLabeledMajorTicks(
        _ majorTicks: [(x: CGFloat, seconds: Double)],
        minLabelSpacing: CGFloat = 72
    ) -> [(x: CGFloat, seconds: Double)] {
        var labeled: [(x: CGFloat, seconds: Double)] = []
        var lastX = -CGFloat.greatestFiniteMagnitude
        for tick in majorTicks where tick.x - lastX >= minLabelSpacing {
            labeled.append(tick)
            lastX = tick.x
        }
        return labeled
    }

    private func markerNearX(_ x: CGFloat, width: CGFloat) -> Double? {
        let markerHitTolerance: CGFloat = 12
        let visibleMarkers = captureMarkers.filter { marker in
            marker.seconds >= visibleStartSeconds && marker.seconds <= visibleEndSeconds
        }
        var best: (seconds: Double, distance: CGFloat)?
        for marker in visibleMarkers {
            let markerX = snapToPixel(xPosition(for: marker.seconds, width: width))
            let distance = abs(markerX - x)
            guard distance <= markerHitTolerance else { continue }
            if let current = best {
                if distance < current.distance {
                    best = (marker.seconds, distance)
                }
            } else {
                best = (marker.seconds, distance)
            }
        }
        return best?.seconds
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let rulerHeight: CGFloat = 16
            let rulerGap: CGFloat = 2
            let markerTopGutter: CGFloat = 8
            let markerBottomGutter: CGFloat = 8
            let timelineVerticalOffset: CGFloat = rulerHeight + rulerGap + markerTopGutter
            let timelineHeight = max(1, height - rulerHeight - rulerGap - markerTopGutter - markerBottomGutter)
            let startX = xPosition(for: startSeconds, width: width)
            let endX = xPosition(for: endSeconds, width: width)
            let selectionStartX = min(startX, endX)
            let selectionEndX = max(startX, endX)
            // Draw only the viewport intersection. This keeps geometry stable at high
            // zoom levels even when the logical clip range spans far outside view.
            let drawSelectionStartX = max(0, selectionStartX)
            let drawSelectionEndX = min(width, selectionEndX)
            let drawSelectionWidth = max(0, drawSelectionEndX - drawSelectionStartX)
            let hasSelection = drawSelectionWidth > 0.5
            let isStartEdgeActive = isStartEdgeHovered || isStartEdgeDragging
            let isEndEdgeActive = isEndEdgeHovered || isEndEdgeDragging
            let isEdgeActive = isStartEdgeActive || isEndEdgeActive
            let edgeHoverProximity: CGFloat = 22
            let edgeHitWidth: CGFloat = edgeHoverProximity * 2
            let edgeVisibilityMargin: CGFloat = max(edgeHitWidth, 36)
            let startEdgeVisible = startX >= -edgeVisibilityMargin && startX <= (width + edgeVisibilityMargin)
            let endEdgeVisible = endX >= -edgeVisibilityMargin && endX <= (width + edgeVisibilityMargin)
            let selectionOutlineOpacity: Double = isEdgeActive ? 1.0 : (isHovered ? 0.98 : 0.92)
            let selectionOutlineWidth: CGFloat = isEdgeActive ? 3.4 : 3.0
            let edgeGlowWidth = min(max(drawSelectionWidth * 0.18, 18), 44)
            let startEdgeGlowOpacity: Double = isStartEdgeDragging ? 1.0 : (isStartEdgeHovered ? 0.78 : 0)
            let endEdgeGlowOpacity: Double = isEndEdgeDragging ? 1.0 : (isEndEdgeHovered ? 0.78 : 0)
            let startBoundaryPulseOpacity: Double = highlightedClipBoundary == .start ? 0.95 : 0
            let endBoundaryPulseOpacity: Double = highlightedClipBoundary == .end ? 0.95 : 0
            let majorStep = rulerMajorStep(for: visibleDuration)
            let minorDivisions = max(1, rulerMinorDivisions(for: majorStep))
            let minorStep = majorStep / Double(minorDivisions)
            let ticks = makeRulerTicks(
                visibleStart: visibleStartSeconds,
                visibleEnd: visibleEndSeconds,
                width: width,
                majorStep: majorStep,
                minorStep: minorStep
            )
            let minorTicks = ticks.minor
            let majorTicks = ticks.major
            let labeledMajorTicks = filterLabeledMajorTicks(majorTicks)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    .fill(Color.black.opacity(isHovered ? 0.16 : 0.12))

                // Dedicated ruler lane for time ticks/labels above the waveform.
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: width, height: rulerHeight)
                    .overlay(alignment: .bottomLeading) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.10))
                            .frame(height: 0.8)
                    }
                    .overlay(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(minorTicks.enumerated()), id: \.offset) { tick in
                                Rectangle()
                                    .fill(Color.primary.opacity(0.10))
                                    .frame(width: 1, height: 3)
                                    .offset(x: tick.element, y: rulerHeight - 4)
                            }
                            ForEach(Array(majorTicks.enumerated()), id: \.offset) { tick in
                                Rectangle()
                                    .fill(Color.primary.opacity(0.18))
                                    .frame(width: 1, height: 6)
                                    .offset(x: tick.element.x, y: rulerHeight - 7)
                            }
                            ForEach(Array(labeledMajorTicks.enumerated()), id: \.offset) { tick in
                                Text(rulerLabel(for: tick.element.seconds, majorStep: majorStep))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.primary.opacity(0.55))
                                    .offset(x: tick.element.x + 2, y: 0)
                            }
                        }
                    }
                    .allowsHitTesting(false)

                if hasSelection {
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    systemAccent.opacity(0.36),
                                    systemAccent.opacity(0.42),
                                    systemAccent.opacity(0.36)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: drawSelectionWidth, height: timelineHeight)
                        .offset(x: drawSelectionStartX, y: timelineVerticalOffset)
                        .overlay(
                            ZStack {
                                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                    .stroke(systemAccent.opacity(selectionOutlineOpacity), lineWidth: selectionOutlineWidth)
                                // Subtle inner shadow for slight depth without heavy contrast.
                                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                    .stroke(Color.black.opacity(0.14), lineWidth: 1.0)
                                    .blur(radius: 0.7)
                                    .mask(
                                        RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [Color.black.opacity(0.75), Color.clear],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                    )
                            }
                                .frame(width: drawSelectionWidth, height: timelineHeight)
                                .offset(x: drawSelectionStartX, y: timelineVerticalOffset)
                                .allowsHitTesting(false)
                        )

                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .fill(Color.white.opacity(selectionFlashOpacity))
                        .frame(width: drawSelectionWidth, height: timelineHeight)
                        .offset(x: drawSelectionStartX, y: timelineVerticalOffset)
                        .allowsHitTesting(false)
                }

                if startEdgeVisible {
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    systemAccent.opacity(startEdgeGlowOpacity),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: edgeGlowWidth, height: timelineHeight)
                        .offset(x: startX, y: timelineVerticalOffset)
                        .animation(.easeOut(duration: 0.16), value: isStartEdgeActive)
                        .allowsHitTesting(false)
                }

                if endEdgeVisible {
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    systemAccent.opacity(endEdgeGlowOpacity)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: edgeGlowWidth, height: timelineHeight)
                        .offset(x: max(startX, endX - edgeGlowWidth), y: timelineVerticalOffset)
                        .animation(.easeOut(duration: 0.16), value: isEndEdgeActive)
                        .allowsHitTesting(false)
                }

                if startEdgeVisible {
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    systemAccent.opacity(startBoundaryPulseOpacity),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: edgeGlowWidth, height: timelineHeight)
                        .offset(x: startX, y: timelineVerticalOffset)
                        .animation(.easeOut(duration: 0.16), value: highlightedClipBoundary)
                        .allowsHitTesting(false)
                }

                if endEdgeVisible {
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    systemAccent.opacity(endBoundaryPulseOpacity)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: edgeGlowWidth, height: timelineHeight)
                        .offset(x: max(startX, endX - edgeGlowWidth), y: timelineVerticalOffset)
                        .animation(.easeOut(duration: 0.16), value: highlightedClipBoundary)
                        .allowsHitTesting(false)
                }

                WaveformRasterLayerView(
                    sourceSessionID: sourceSessionID,
                    samples: samples,
                    zoomLevel: zoomLevel,
                    renderBuckets: renderBuckets,
                    totalDurationSeconds: totalDurationSeconds,
                    visibleStartSeconds: visibleStartSeconds,
                    visibleEndSeconds: visibleEndSeconds,
                    isDarkAppearance: colorScheme == .dark,
                    playheadSeconds: visualPlayheadSeconds,
                    playheadJumpFromSeconds: playheadJumpFromSeconds,
                    playheadJumpAnimationToken: playheadJumpAnimationToken,
                    isPlayheadCaptureFlashing: isPlayheadCaptureFlashing,
                    captureMarkers: captureMarkers,
                    highlightedMarkerID: highlightedMarkerID,
                    onMarkerSeek: { seconds in
                        onSeek(seconds, true)
                    }
                )
                .frame(maxWidth: .infinity, minHeight: timelineHeight, maxHeight: timelineHeight, alignment: .center)
                .offset(y: timelineVerticalOffset)

                if startEdgeVisible {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: edgeHitWidth, height: timelineHeight)
                        .contentShape(Rectangle())
                        .offset(x: startX - (edgeHitWidth / 2), y: timelineVerticalOffset)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("waveformTimeline"))
                                .onChanged { value in
                                    if startEdgeDragAnchor == nil {
                                        startEdgeDragAnchor = startSeconds
                                    }
                                    isStartEdgeDragging = true
                                    isEndEdgeHovered = false
                                    NSCursor.closedHand.set()
                                    let anchor = startEdgeDragAnchor ?? startSeconds
                                    let deltaSeconds = Double(value.translation.width / max(width, 1)) * visibleDuration
                                    let newValue = min(max(0, anchor + deltaSeconds), endSeconds)
                                    onSetStart(newValue)
                                }
                                .onEnded { _ in
                                    startEdgeDragAnchor = nil
                                    isStartEdgeDragging = false
                                    if isStartEdgeHovered || isEndEdgeHovered {
                                        NSCursor.resizeLeftRight.set()
                                    } else {
                                        NSCursor.arrow.set()
                                    }
                                }
                        )
                }

                if endEdgeVisible {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: edgeHitWidth, height: timelineHeight)
                        .contentShape(Rectangle())
                        .offset(x: endX - (edgeHitWidth / 2), y: timelineVerticalOffset)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("waveformTimeline"))
                                .onChanged { value in
                                    if endEdgeDragAnchor == nil {
                                        endEdgeDragAnchor = endSeconds
                                    }
                                    isEndEdgeDragging = true
                                    isStartEdgeHovered = false
                                    NSCursor.closedHand.set()
                                    let anchor = endEdgeDragAnchor ?? endSeconds
                                    let deltaSeconds = Double(value.translation.width / max(width, 1)) * visibleDuration
                                    let newValue = max(min(totalDurationSeconds, anchor + deltaSeconds), startSeconds)
                                    onSetEnd(newValue)
                                }
                                .onEnded { _ in
                                    endEdgeDragAnchor = nil
                                    isEndEdgeDragging = false
                                    if isStartEdgeHovered || isEndEdgeHovered {
                                        NSCursor.resizeLeftRight.set()
                                    } else {
                                        NSCursor.arrow.set()
                                    }
                                }
                        )
                }

                if hasSelection {
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .stroke(Color.white.opacity(0.95), lineWidth: 2.0)
                        .frame(width: drawSelectionWidth)
                        .frame(height: max(1, timelineHeight - 8))
                        .offset(x: drawSelectionStartX, y: timelineVerticalOffset + 4)
                        .shadow(color: Color.accentColor.opacity(selectionFlashGlowOpacity), radius: 14)
                        .opacity(selectionFlashGlowOpacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .clipped()
            .coordinateSpace(name: "waveformTimeline")
            .overlay(
                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    .stroke(isHovered ? Color.accentColor.opacity(0.28) : Color.gray.opacity(0.16), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                onHoverChanged(hovering)
                if !hovering && !isStartEdgeDragging && !isEndEdgeDragging {
                    isStartEdgeHovered = false
                    isEndEdgeHovered = false
                    isResizeCursorActive = false
                    NSCursor.arrow.set()
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard !isStartEdgeDragging && !isEndEdgeDragging else { return }
                switch phase {
                case .active(let point):
                    let x = point.x
                    let pointerTime = timeValue(
                        for: x,
                        width: width,
                        windowStart: visibleStartSeconds,
                        windowEnd: visibleEndSeconds
                    )
                    onPointerTimeChanged(pointerTime)
                    let startDistance = abs(x - startX)
                    let endDistance = abs(x - endX)
                    let isNearStart = startDistance <= edgeHoverProximity
                    let isNearEnd = endDistance <= edgeHoverProximity
                    var nextStartEdgeHovered = false
                    var nextEndEdgeHovered = false

                    if isNearStart && isNearEnd {
                        if startDistance <= endDistance {
                            nextStartEdgeHovered = true
                        } else {
                            nextEndEdgeHovered = true
                        }
                    } else if isNearStart {
                        nextStartEdgeHovered = true
                    } else if isNearEnd {
                        nextEndEdgeHovered = true
                    }

                    if nextStartEdgeHovered != isStartEdgeHovered {
                        isStartEdgeHovered = nextStartEdgeHovered
                    }
                    if nextEndEdgeHovered != isEndEdgeHovered {
                        isEndEdgeHovered = nextEndEdgeHovered
                    }

                    let shouldUseResizeCursor = nextStartEdgeHovered || nextEndEdgeHovered
                    if shouldUseResizeCursor && !isResizeCursorActive {
                        isResizeCursorActive = true
                        NSCursor.resizeLeftRight.set()
                    } else if !shouldUseResizeCursor && isResizeCursorActive {
                        isResizeCursorActive = false
                        NSCursor.arrow.set()
                    }
                case .ended:
                    onPointerTimeChanged(nil)
                    isStartEdgeHovered = false
                    isEndEdgeHovered = false
                    isResizeCursorActive = false
                    if !isHovered {
                        NSCursor.arrow.set()
                    }
                }
            }
            .task(id: quickExportFlashToken) {
                guard quickExportFlashToken > 0 else { return }
                withAnimation(.easeOut(duration: 0.14)) {
                    selectionFlashOpacity = 0.52
                    selectionFlashGlowOpacity = 1.0
                }
                try? await Task.sleep(nanoseconds: 260_000_000)
                withAnimation(.easeOut(duration: 0.34)) {
                    selectionFlashOpacity = 0
                    selectionFlashGlowOpacity = 0
                }
            }
            .task(id: captureFrameFlashToken) {
                guard captureFrameFlashToken > 0 else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    isPlayheadCaptureFlashing = true
                }
                try? await Task.sleep(nanoseconds: 220_000_000)
                withAnimation(.easeOut(duration: 0.2)) {
                    isPlayheadCaptureFlashing = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let isFirstDragEvent = !didStartPlayheadDrag
                        let shouldSnapToMarker = isFirstDragEvent
                        if !didStartPlayheadDrag {
                            didStartPlayheadDrag = true
                            onPlayheadDragStateChanged(true)
                        }
                        if let snapLock = markerSnapLockSeconds {
                            // Keep click-to-snap stable across micro movement/noise.
                            if abs(value.translation.width) <= 3 && abs(value.translation.height) <= 3 {
                                onSeek(snapLock, true)
                                return
                            }
                            markerSnapLockSeconds = nil
                        }
                        onPlayheadDragEdgePan(value.location.x, width)
                        if isFirstDragEvent,
                           let markerSeconds = markerNearX(value.location.x, width: width) {
                            markerSnapLockSeconds = markerSeconds
                            onSeek(markerSeconds, true)
                            return
                        }
                        onSeek(
                            timeValue(for: value.location.x, width: width, windowStart: visibleStartSeconds, windowEnd: visibleEndSeconds),
                            shouldSnapToMarker
                        )
                    }
                    .onEnded { _ in
                        didStartPlayheadDrag = false
                        markerSnapLockSeconds = nil
                        onPlayheadDragStateChanged(false)
                    }
            , including: .gesture)
            .overlay(alignment: .bottomLeading) {
                Text(formatSeconds(visibleStartSeconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.black.opacity(0.78))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                    )
                    .padding(.leading, 6)
                    .padding(.bottom, 4)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(formatSeconds(visibleEndSeconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.black.opacity(0.78))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                    )
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
                    .allowsHitTesting(false)
            }
        }
    }
}

private final class WaveformRasterHostView: NSView {
    struct MarkerHotspot {
        let id: UUID
        let seconds: Double
        let x: CGFloat
    }

    let waveformClipLayer = CALayer()
    let waveformLayer = CALayer()
    let markerContainerLayer = CALayer()
    let playheadLayer = CALayer()
    var onMarkerSeek: ((Double) -> Void)?
    var markerHotspots: [MarkerHotspot] = []
    var markerLayersByID: [UUID: CALayer] = [:]
    private var trackingAreaRef: NSTrackingArea?
    private var markerCursorActive = false
    private let markerHitTolerance: CGFloat = 12
    private var hoveredMarkerID: UUID? {
        didSet {
            applyMarkerHoverState(animated: true)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        waveformClipLayer.masksToBounds = true
        waveformClipLayer.cornerCurve = .continuous
        waveformClipLayer.cornerRadius = UIRadius.small
        waveformLayer.contentsGravity = .resize
        waveformLayer.magnificationFilter = .linear
        waveformLayer.minificationFilter = .linear
        waveformLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        waveformLayer.actions = [
            "contents": NSNull(),
            "contentsRect": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        markerContainerLayer.actions = [
            "sublayers": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        markerContainerLayer.masksToBounds = false
        markerContainerLayer.isGeometryFlipped = true
        playheadLayer.backgroundColor = NSColor.systemRed.cgColor
        playheadLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "opacity": NSNull(),
            "shadowOpacity": NSNull(),
            "shadowRadius": NSNull()
        ]
        waveformClipLayer.addSublayer(waveformLayer)
        layer?.addSublayer(waveformClipLayer)
        layer?.addSublayer(markerContainerLayer)
        layer?.addSublayer(playheadLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .inVisibleRect,
            .mouseMoved,
            .mouseEnteredAndExited
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    private func markerNear(point: NSPoint) -> MarkerHotspot? {
        // Shared hover/click hit test so both behaviors match exactly.
        markerHotspots.first(where: { abs($0.x - point.x) <= markerHitTolerance })
    }

    func applyMarkerHoverState(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        for (id, layer) in markerLayersByID {
            let isHighlighted = (layer.value(forKey: "isHighlighted") as? Bool) ?? false
            let isHovered = id == hoveredMarkerID
            let targetShadowOpacity: Float = {
                if isHighlighted && isHovered { return 0.86 }
                if isHighlighted { return 0.6 }
                if isHovered { return 0.38 }
                return 0.0
            }()
            let targetShadowRadius: CGFloat = {
                if isHighlighted && isHovered { return 6.2 }
                if isHighlighted { return 4.0 }
                if isHovered { return 3.0 }
                return 0.0
            }()
            let targetScale: CGFloat = {
                if isHighlighted && isHovered { return 1.12 }
                if isHighlighted { return 1.0 }
                if isHovered { return 1.08 }
                return 1.0
            }()

            if animated {
                let shadowAnim = CABasicAnimation(keyPath: "shadowOpacity")
                shadowAnim.fromValue = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
                shadowAnim.toValue = targetShadowOpacity
                shadowAnim.duration = 0.12
                shadowAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                shadowAnim.isRemovedOnCompletion = true
                layer.add(shadowAnim, forKey: "hoverShadowOpacity")

                let radiusAnim = CABasicAnimation(keyPath: "shadowRadius")
                radiusAnim.fromValue = layer.presentation()?.shadowRadius ?? layer.shadowRadius
                radiusAnim.toValue = targetShadowRadius
                radiusAnim.duration = 0.12
                radiusAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                radiusAnim.isRemovedOnCompletion = true
                layer.add(radiusAnim, forKey: "hoverShadowRadius")

                let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
                scaleAnim.fromValue = (layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1.0
                scaleAnim.toValue = targetScale
                scaleAnim.duration = 0.12
                scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scaleAnim.isRemovedOnCompletion = true
                layer.add(scaleAnim, forKey: "hoverScale")
            }

            layer.shadowOpacity = targetShadowOpacity
            layer.shadowRadius = targetShadowRadius
            layer.transform = CATransform3DMakeScale(targetScale, targetScale, 1)
        }
        CATransaction.commit()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let marker = markerNear(point: point) {
            hoveredMarkerID = marker.id
            if !markerCursorActive {
                NSCursor.pointingHand.set()
                markerCursorActive = true
            }
        } else if markerCursorActive {
            hoveredMarkerID = nil
            NSCursor.arrow.set()
            markerCursorActive = false
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredMarkerID = nil
        if markerCursorActive {
            NSCursor.arrow.set()
            markerCursorActive = false
        }
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // Marker click-to-seek is handled in the SwiftUI gesture path so
        // hover/click use one resolver and avoid double-seek race conditions.
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        waveformClipLayer.frame = bounds
        waveformLayer.frame = waveformClipLayer.bounds
        markerContainerLayer.frame = bounds
    }
}

private final class WaveformRasterCoordinator {
    private var zoomRenderBuckets: [Double] = [1, 2, 4, 8, 16, 32, 64, 96, 128, 192, 256]
    private(set) var cachedSessionID: UUID?
    private(set) var cachedSamples: [Double] = []
    private(set) var cachedBucketImages: [Double: CGImage] = [:]
    private(set) var cachedIsDarkAppearance = false
    var lastAppliedContentsRect: CGRect = .null
    var lastContentsRectUpdateTime: CFTimeInterval = 0
    var lastAppliedBounds: CGRect = .zero
    var lastAppliedZoomBucket: Double = -1
    var lastPlayheadJumpAnimationToken: Int = -1
    var lastPlayheadCaptureFlashing: Bool = false
    var lastHighlightedMarkerID: UUID?

    func setZoomRenderBuckets(_ buckets: [Double]) {
        let normalized = Array(Set(buckets.map { max(1, $0) })).sorted()
        guard !normalized.isEmpty, normalized != zoomRenderBuckets else { return }
        zoomRenderBuckets = normalized
        let keep = Set(zoomRenderBuckets)
        cachedBucketImages = cachedBucketImages.filter { keep.contains($0.key) }
        lastAppliedZoomBucket = -1
    }

    @discardableResult
    func rebuildImageIfNeeded(sessionID: UUID, samples: [Double], isDarkAppearance: Bool) -> Bool {
        let needsRebuild =
            cachedBucketImages.isEmpty ||
            cachedSessionID != sessionID ||
            cachedSamples.count != samples.count ||
            cachedIsDarkAppearance != isDarkAppearance

        guard needsRebuild else { return false }

        cachedSessionID = sessionID
        cachedSamples = samples
        cachedIsDarkAppearance = isDarkAppearance
        cachedBucketImages = [:]
        lastAppliedContentsRect = .null
        lastContentsRectUpdateTime = 0
        lastAppliedBounds = .zero
        lastAppliedZoomBucket = -1
        return true
    }

    func image(for zoomBucket: Double) -> CGImage? {
        if let cached = cachedBucketImages[zoomBucket] {
            return cached
        }
        guard !cachedSamples.isEmpty else { return nil }
        let width = Int(min(98_304, max(4_096, (1_024.0 * zoomBucket).rounded())))
        let peaks = makePeaks(samples: cachedSamples, targetWidth: width)
        guard let image = makeWaveformImage(
            peaks: peaks,
            height: 96,
            isDarkAppearance: cachedIsDarkAppearance,
            useSkippedColumns: zoomBucket >= 32,
            zoomBucket: zoomBucket
        ) else {
            return nil
        }
        cachedBucketImages[zoomBucket] = image
        return image
    }

    private func makePeaks(samples: [Double], targetWidth: Int) -> [Double] {
        let width = max(1, targetWidth)
        let n = max(samples.count - 1, 1)
        var peaks = Array(repeating: 0.0, count: width)
        for x in 0..<width {
            let startRatio = Double(x) / Double(width)
            let endRatio = Double(x + 1) / Double(width)
            var startIndex = Int((startRatio * Double(n)).rounded(.down))
            var endIndex = Int((endRatio * Double(n)).rounded(.up))
            startIndex = min(max(0, startIndex), n)
            endIndex = min(max(startIndex, endIndex), n)
            var peak = 0.0
            var i = startIndex
            while i <= endIndex {
                peak = max(peak, samples[i])
                i += 1
            }
            peaks[x] = peak
        }
        return peaks
    }

    private func makeWaveformImage(
        peaks: [Double],
        height: Int,
        isDarkAppearance: Bool,
        useSkippedColumns: Bool,
        zoomBucket: Double
    ) -> CGImage? {
        guard !peaks.isEmpty else { return nil }

        let width = peaks.count
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let barAlpha: CGFloat = {
            if zoomBucket >= 32 {
                return isDarkAppearance ? 0.64 : 0.58
            }
            return isDarkAppearance ? 0.43 : 0.37
        }()
        let barColor: NSColor = {
            if isDarkAppearance {
                return NSColor(calibratedWhite: 1.0, alpha: barAlpha)
            }
            return NSColor.labelColor.withAlphaComponent(barAlpha)
        }()
        context.setFillColor(barColor.cgColor)

        let baselineY = 2.0
        let maxBarHeight = max(1.0, CGFloat(height) - 4.0)

        let minNormalizedBar: Double = {
            if zoomBucket >= 32 { return 0.02 }
            return 0.01
        }()

        for x in 0..<width {
            if useSkippedColumns && x % 2 != 0 {
                continue
            }
            let peak = peaks[x]
            let normalized = max(minNormalizedBar, min(1.0, peak))
            let amp = CGFloat(normalized) * maxBarHeight
            let rect = CGRect(x: CGFloat(x), y: baselineY, width: 1, height: amp)
            context.fill(rect)
        }

        return context.makeImage()
    }

    func bestZoomRenderBucket(for zoomLevel: Double) -> Double {
        for bucket in zoomRenderBuckets where bucket >= zoomLevel {
            return bucket
        }
        return zoomRenderBuckets.last ?? max(1, zoomLevel)
    }
}

private struct WaveformRasterLayerView: NSViewRepresentable, Equatable {
    let sourceSessionID: UUID
    let samples: [Double]
    let zoomLevel: Double
    let renderBuckets: [Double]
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let isDarkAppearance: Bool
    let playheadSeconds: Double
    let playheadJumpFromSeconds: Double
    let playheadJumpAnimationToken: Int
    let isPlayheadCaptureFlashing: Bool
    let captureMarkers: [CaptureTimelineMarker]
    let highlightedMarkerID: UUID?
    let onMarkerSeek: (Double) -> Void

    static func == (lhs: WaveformRasterLayerView, rhs: WaveformRasterLayerView) -> Bool {
        lhs.sourceSessionID == rhs.sourceSessionID &&
        lhs.samples.count == rhs.samples.count &&
        abs(lhs.zoomLevel - rhs.zoomLevel) < 0.0001 &&
        lhs.renderBuckets == rhs.renderBuckets &&
        abs(lhs.totalDurationSeconds - rhs.totalDurationSeconds) < 0.0001 &&
        abs(lhs.visibleStartSeconds - rhs.visibleStartSeconds) < 0.0001 &&
        abs(lhs.visibleEndSeconds - rhs.visibleEndSeconds) < 0.0001 &&
        lhs.isDarkAppearance == rhs.isDarkAppearance &&
        abs(lhs.playheadSeconds - rhs.playheadSeconds) < 0.0001 &&
        abs(lhs.playheadJumpFromSeconds - rhs.playheadJumpFromSeconds) < 0.0001 &&
        lhs.playheadJumpAnimationToken == rhs.playheadJumpAnimationToken &&
        lhs.isPlayheadCaptureFlashing == rhs.isPlayheadCaptureFlashing &&
        lhs.captureMarkers == rhs.captureMarkers &&
        lhs.highlightedMarkerID == rhs.highlightedMarkerID
    }

    func makeCoordinator() -> WaveformRasterCoordinator {
        WaveformRasterCoordinator()
    }

    func makeNSView(context: Context) -> WaveformRasterHostView {
        let view = WaveformRasterHostView()
        view.onMarkerSeek = onMarkerSeek
        return view
    }

    func updateNSView(_ nsView: WaveformRasterHostView, context: Context) {
        nsView.onMarkerSeek = onMarkerSeek
        context.coordinator.setZoomRenderBuckets(renderBuckets)

        let didRebuildImage = context.coordinator.rebuildImageIfNeeded(
            sessionID: sourceSessionID,
            samples: samples,
            isDarkAppearance: isDarkAppearance
        )

        guard !context.coordinator.cachedSamples.isEmpty else {
            nsView.waveformLayer.contents = nil
            return
        }

        let duration = max(0.0001, totalDurationSeconds)
        let rawStartNorm = min(max(0, visibleStartSeconds / duration), 1.0)
        let rawEndNorm = min(max(rawStartNorm + 0.000001, visibleEndSeconds / duration), 1.0)
        let zoomBucket = context.coordinator.bestZoomRenderBucket(for: zoomLevel)
        let image = context.coordinator.image(for: zoomBucket)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if let image,
           (didRebuildImage || context.coordinator.lastAppliedZoomBucket != zoomBucket || nsView.waveformLayer.contents == nil) {
            nsView.waveformLayer.contents = image
            context.coordinator.lastAppliedZoomBucket = zoomBucket
            nsView.waveformLayer.magnificationFilter = zoomBucket >= 32 ? .nearest : .linear
            nsView.waveformLayer.minificationFilter = .linear
        }

        guard let activeImage = image else {
            nsView.waveformLayer.contents = nil
            CATransaction.commit()
            return
        }
        _ = activeImage
        let newContentsRect = CGRect(
            x: rawStartNorm,
            y: 0,
            width: max(0.000001, rawEndNorm - rawStartNorm),
            height: 1
        )

        if !newContentsRect.equalTo(context.coordinator.lastAppliedContentsRect) {
            let oldRect = context.coordinator.lastAppliedContentsRect
            let now = CACurrentMediaTime()
            let lastUpdate = context.coordinator.lastContentsRectUpdateTime
            // If updates are arriving rapidly, treat as continuous interaction
            // (drag/scroll) and avoid heavy catch-up animations.
            let isContinuousViewportInteraction = lastUpdate > 0 && (now - lastUpdate) < 0.08
            if oldRect != .null {
                let deltaX = abs(newContentsRect.origin.x - oldRect.origin.x)
                // Smooth large viewport jumps (keyboard marker nav / fast thumb pan).
                if deltaX > 0.03 && !isContinuousViewportInteraction {
                    let anim = CABasicAnimation(keyPath: "contentsRect")
                    anim.fromValue = oldRect
                    anim.toValue = newContentsRect
                    anim.duration = 0.22
                    anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    anim.isRemovedOnCompletion = true
                    nsView.waveformLayer.add(anim, forKey: "viewportRecenter")
                }
            }
            nsView.waveformLayer.contentsRect = newContentsRect
            context.coordinator.lastAppliedContentsRect = newContentsRect

            if oldRect != .null {
                let deltaX = abs(newContentsRect.origin.x - oldRect.origin.x)
                if deltaX > 0.03 && !isContinuousViewportInteraction {
                    let normWidth = max(0.000001, newContentsRect.width)
                    let markerScrollShiftX = CGFloat((newContentsRect.origin.x - oldRect.origin.x) / normWidth) * nsView.bounds.width
                    if markerScrollShiftX != 0 {
                        let markerPan = CABasicAnimation(keyPath: "sublayerTransform.translation.x")
                        markerPan.fromValue = markerScrollShiftX
                        markerPan.toValue = 0
                        markerPan.duration = 0.22
                        markerPan.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        markerPan.isRemovedOnCompletion = true
                        nsView.markerContainerLayer.add(markerPan, forKey: "viewportRecenterMarkers")
                    }
                }
            }
            context.coordinator.lastContentsRectUpdateTime = now
        }

        if !nsView.bounds.equalTo(context.coordinator.lastAppliedBounds) {
            nsView.waveformLayer.frame = nsView.bounds
            context.coordinator.lastAppliedBounds = nsView.bounds
        }

        let visibleDuration = max(0.0001, visibleEndSeconds - visibleStartSeconds)
        let width = nsView.bounds.width
        func xPosition(for seconds: Double) -> CGFloat {
            let local = seconds - visibleStartSeconds
            return CGFloat(local / visibleDuration) * width
        }
        let backingScale = nsView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let pixel = CGFloat(1.0 / backingScale)
        func snapToPixel(_ value: CGFloat) -> CGFloat {
            (value / pixel).rounded() * pixel
        }

        let playheadX = snapToPixel(xPosition(for: playheadSeconds))
        let playheadWidth: CGFloat = isPlayheadCaptureFlashing ? 3.6 : 2.0
        let targetPlayheadFrame = CGRect(
            x: playheadX - (playheadWidth / 2.0),
            y: -4,
            width: playheadWidth,
            height: nsView.bounds.height + 8
        )
        if playheadJumpAnimationToken != context.coordinator.lastPlayheadJumpAnimationToken {
            let fromX = xPosition(for: playheadJumpFromSeconds)
            let toX = targetPlayheadFrame.midX
            if abs(toX - fromX) > 0.5 {
                let move = CABasicAnimation(keyPath: "position.x")
                move.fromValue = fromX
                move.toValue = toX
                move.duration = 0.22
                move.timingFunction = CAMediaTimingFunction(name: .easeOut)
                move.isRemovedOnCompletion = true
                nsView.playheadLayer.add(move, forKey: "playheadJump")
            }
            context.coordinator.lastPlayheadJumpAnimationToken = playheadJumpAnimationToken
        }

        nsView.playheadLayer.frame = targetPlayheadFrame
        let playheadVisible = playheadX >= -6 && playheadX <= (width + 6)
        nsView.playheadLayer.opacity = playheadVisible ? 1.0 : 0.0
        nsView.playheadLayer.shadowColor = NSColor.systemRed.cgColor
        let targetShadowOpacity: Float = isPlayheadCaptureFlashing ? 0.9 : 0.0
        let targetShadowRadius: CGFloat = isPlayheadCaptureFlashing ? 6 : 0
        if isPlayheadCaptureFlashing != context.coordinator.lastPlayheadCaptureFlashing {
            let shadowOpacityAnim = CABasicAnimation(keyPath: "shadowOpacity")
            shadowOpacityAnim.fromValue = nsView.playheadLayer.presentation()?.shadowOpacity ?? nsView.playheadLayer.shadowOpacity
            shadowOpacityAnim.toValue = targetShadowOpacity
            shadowOpacityAnim.duration = isPlayheadCaptureFlashing ? 0.08 : 0.2
            shadowOpacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shadowOpacityAnim.isRemovedOnCompletion = true
            nsView.playheadLayer.add(shadowOpacityAnim, forKey: "playheadShadowOpacity")

            let shadowRadiusAnim = CABasicAnimation(keyPath: "shadowRadius")
            shadowRadiusAnim.fromValue = nsView.playheadLayer.presentation()?.shadowRadius ?? nsView.playheadLayer.shadowRadius
            shadowRadiusAnim.toValue = targetShadowRadius
            shadowRadiusAnim.duration = shadowOpacityAnim.duration
            shadowRadiusAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shadowRadiusAnim.isRemovedOnCompletion = true
            nsView.playheadLayer.add(shadowRadiusAnim, forKey: "playheadShadowRadius")
        }
        nsView.playheadLayer.shadowOpacity = targetShadowOpacity
        nsView.playheadLayer.shadowRadius = targetShadowRadius
        context.coordinator.lastPlayheadCaptureFlashing = isPlayheadCaptureFlashing

        let markerContainer = nsView.markerContainerLayer
        let visibleMarkers = captureMarkers.enumerated().filter { _, marker in
            marker.seconds >= visibleStartSeconds && marker.seconds <= visibleEndSeconds
        }
        var markerHotspots: [WaveformRasterHostView.MarkerHotspot] = []
        var markerLayersByID: [UUID: CALayer] = [:]
        markerContainer.sublayers = visibleMarkers.map { _, marker in
            let markerX = snapToPixel(xPosition(for: marker.seconds))
            markerHotspots.append(.init(id: marker.id, seconds: marker.seconds, x: markerX))
            let isHighlighted = marker.id == highlightedMarkerID
            let pinColor = NSColor.systemOrange.withAlphaComponent(isHighlighted ? 1.0 : 0.9)

            let pin = CALayer()
            // Keep pinhead visually above timeline while leaving most of it inside hit-testable bounds.
            pin.frame = CGRect(x: markerX - (isHighlighted ? 4.5 : 4.0), y: -2, width: isHighlighted ? 9 : 8, height: nsView.bounds.height + 6)
            pin.setValue(isHighlighted, forKey: "isHighlighted")

            let head = CALayer()
            head.backgroundColor = pinColor.cgColor
            head.frame = CGRect(x: 0, y: 0, width: isHighlighted ? 9 : 8, height: isHighlighted ? 9 : 8)
            head.cornerRadius = head.bounds.width / 2
            pin.addSublayer(head)

            let stem = CALayer()
            stem.backgroundColor = NSColor.systemOrange.withAlphaComponent(isHighlighted ? 0.96 : 0.8).cgColor
            let stemWidth: CGFloat = isHighlighted ? 2.6 : 2.0
            stem.frame = CGRect(x: (head.bounds.width - stemWidth) / 2.0, y: head.frame.maxY, width: stemWidth, height: nsView.bounds.height + 4)
            pin.addSublayer(stem)

            pin.shadowColor = NSColor.systemOrange.cgColor
            pin.shadowOpacity = isHighlighted ? 0.6 : 0
            pin.shadowRadius = isHighlighted ? 4 : 0
            markerLayersByID[marker.id] = pin
            return pin
        }
        nsView.markerHotspots = markerHotspots
        nsView.markerLayersByID = markerLayersByID
        nsView.applyMarkerHoverState(animated: false)

        if highlightedMarkerID != context.coordinator.lastHighlightedMarkerID,
           let highlightedMarkerID,
           let visibleIndex = visibleMarkers.firstIndex(where: { $0.element.id == highlightedMarkerID }),
           let markerLayers = markerContainer.sublayers,
           visibleIndex >= 0, visibleIndex < markerLayers.count {
            let pinLayer = markerLayers[visibleIndex]
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0.0
            glow.toValue = 0.6
            glow.duration = 0.16
            glow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            glow.isRemovedOnCompletion = true
            pinLayer.add(glow, forKey: "markerGlow")

            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1.0
            pulse.toValue = 1.09
            pulse.duration = 0.10
            pulse.autoreverses = true
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.isRemovedOnCompletion = true
            pinLayer.add(pulse, forKey: "markerPulse")
        }
        context.coordinator.lastHighlightedMarkerID = highlightedMarkerID

        CATransaction.commit()
    }
}

struct UnifiedClipTimelineSelector: View {
    @Binding var startSeconds: Double
    @Binding var playheadSeconds: Double
    @Binding var endSeconds: Double
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let captureMarkers: [CaptureTimelineMarker]
    let highlightedMarkerID: UUID?
    let onSeek: (Double) -> Void
    @State private var seekDragWindowStart: Double?
    @State private var seekDragWindowEnd: Double?
    @State private var isHovered = false
    @State private var isStartHandleHovered = false
    @State private var isEndHandleHovered = false
    @State private var startHandleDragAnchor: Double?
    @State private var endHandleDragAnchor: Double?

    private var visibleDuration: Double {
        max(0.0001, visibleEndSeconds - visibleStartSeconds)
    }

    private func xPosition(for value: Double, width: CGFloat) -> CGFloat {
        let local = value - visibleStartSeconds
        return CGFloat(min(max(0, local / visibleDuration), 1.0)) * width
    }

    private func timeValue(for x: CGFloat, width: CGFloat, windowStart: Double, windowEnd: Double) -> Double {
        guard width > 0 else { return 0 }
        let ratio = min(max(0, x / width), 1.0)
        let duration = max(0.0001, windowEnd - windowStart)
        return min(totalDurationSeconds, max(0, windowStart + (Double(ratio) * duration)))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let startX = xPosition(for: startSeconds, width: width)
            let playheadX = xPosition(for: playheadSeconds, width: width)
            let endX = xPosition(for: endSeconds, width: width)
            let handleSize: CGFloat = 16
            let handleOffsetY: CGFloat = 13

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    .fill(Color.black.opacity(isHovered ? 0.30 : 0.24))
                    .frame(height: 10)
                    .offset(y: 15)

                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.85),
                                Color.accentColor.opacity(0.95),
                                Color.blue.opacity(0.85)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, endX - startX), height: 10)
                    .offset(x: startX, y: 15)
                    .overlay(
                        RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                            .frame(width: max(2, endX - startX), height: 10)
                            .offset(x: startX, y: 15)
                    )

                ForEach(captureMarkers) { marker in
                    let markerX = xPosition(for: marker.seconds, width: width)
                    let isHighlighted = marker.id == highlightedMarkerID
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(isHighlighted ? Color.orange : Color.orange.opacity(0.74))
                        .frame(width: isHighlighted ? 5 : 3, height: isHighlighted ? 24 : 18)
                        .scaleEffect(isHighlighted ? 1.12 : 1.0, anchor: .center)
                        .shadow(
                            color: isHighlighted ? Color.orange.opacity(0.5) : Color.clear,
                            radius: isHighlighted ? 4 : 0
                        )
                        .offset(x: markerX - (isHighlighted ? 2.5 : 1.5), y: isHighlighted ? 8 : 11)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 2, height: 24)
                    .offset(x: playheadX - 1, y: 8)
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 16, height: 28)
                    .contentShape(Rectangle())
                    .offset(x: playheadX - 8, y: 6)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if seekDragWindowStart == nil || seekDragWindowEnd == nil {
                                    seekDragWindowStart = visibleStartSeconds
                                    seekDragWindowEnd = visibleEndSeconds
                                }
                                let windowStart = seekDragWindowStart ?? visibleStartSeconds
                                let windowEnd = seekDragWindowEnd ?? visibleEndSeconds
                                let newValue = timeValue(for: value.location.x, width: width, windowStart: windowStart, windowEnd: windowEnd)
                                onSeek(newValue)
                            }
                            .onEnded { _ in
                                seekDragWindowStart = nil
                                seekDragWindowEnd = nil
                            }
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: handleSize, height: handleSize)
                    .overlay(
                        Circle()
                            .stroke(Color.accentColor.opacity(0.95), lineWidth: 2)
                            .frame(width: handleSize, height: handleSize)
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(isStartHandleHovered ? 0.9 : 0), lineWidth: 1.5)
                            .scaleEffect(isStartHandleHovered ? 1.3 : 1.0)
                            .animation(.easeOut(duration: 0.12), value: isStartHandleHovered)
                    )
                    .shadow(color: Color.accentColor.opacity(isStartHandleHovered ? 0.35 : 0), radius: isStartHandleHovered ? 5 : 0)
                    .offset(x: startX - (handleSize / 2), y: handleOffsetY)
                    .allowsHitTesting(false)

                Circle()
                    .fill(Color.clear)
                    .frame(width: handleSize, height: handleSize)
                    .contentShape(Circle())
                    .offset(x: startX - (handleSize / 2), y: handleOffsetY)
                    .onHover { isOver in
                        isStartHandleHovered = isOver
                    }
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("clipTimelineTrack"))
                            .onChanged { value in
                                if startHandleDragAnchor == nil {
                                    startHandleDragAnchor = startSeconds
                                }
                                let anchor = startHandleDragAnchor ?? startSeconds
                                let deltaSeconds = Double(value.translation.width / max(width, 1)) * visibleDuration
                                let newValue = min(max(0, anchor + deltaSeconds), endSeconds)
                                startSeconds = newValue
                            }
                            .onEnded { _ in
                                startHandleDragAnchor = nil
                            }
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: handleSize, height: handleSize)
                    .overlay(
                        Circle()
                            .stroke(Color.accentColor.opacity(0.95), lineWidth: 2)
                            .frame(width: handleSize, height: handleSize)
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(isEndHandleHovered ? 0.9 : 0), lineWidth: 1.5)
                            .scaleEffect(isEndHandleHovered ? 1.3 : 1.0)
                            .animation(.easeOut(duration: 0.12), value: isEndHandleHovered)
                    )
                    .shadow(color: Color.accentColor.opacity(isEndHandleHovered ? 0.35 : 0), radius: isEndHandleHovered ? 5 : 0)
                    .offset(x: endX - (handleSize / 2), y: handleOffsetY)
                    .allowsHitTesting(false)

                Circle()
                    .fill(Color.clear)
                    .frame(width: handleSize, height: handleSize)
                    .contentShape(Circle())
                    .offset(x: endX - (handleSize / 2), y: handleOffsetY)
                    .onHover { isOver in
                        isEndHandleHovered = isOver
                    }
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("clipTimelineTrack"))
                            .onChanged { value in
                                if endHandleDragAnchor == nil {
                                    endHandleDragAnchor = endSeconds
                                }
                                let anchor = endHandleDragAnchor ?? endSeconds
                                let deltaSeconds = Double(value.translation.width / max(width, 1)) * visibleDuration
                                let newValue = max(min(totalDurationSeconds, anchor + deltaSeconds), startSeconds)
                                endSeconds = newValue
                            }
                            .onEnded { _ in
                                endHandleDragAnchor = nil
                            }
                    )
            }
            .coordinateSpace(name: "clipTimelineTrack")
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: highlightedMarkerID)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if seekDragWindowStart == nil || seekDragWindowEnd == nil {
                            seekDragWindowStart = visibleStartSeconds
                            seekDragWindowEnd = visibleEndSeconds
                        }
                        let windowStart = seekDragWindowStart ?? visibleStartSeconds
                        let windowEnd = seekDragWindowEnd ?? visibleEndSeconds
                        let newValue = timeValue(for: value.location.x, width: width, windowStart: windowStart, windowEnd: windowEnd)
                        onSeek(newValue)
                    }
                    .onEnded { _ in
                        seekDragWindowStart = nil
                        seekDragWindowEnd = nil
                    }
            , including: .gesture)
        }
    }
}

struct TimelineViewportScroller: View {
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let onViewportStartChanged: (Double) -> Void
    var body: some View {
        NativeTimelineScroller(
            totalDurationSeconds: totalDurationSeconds,
            visibleStartSeconds: visibleStartSeconds,
            visibleEndSeconds: visibleEndSeconds,
            onViewportStartChanged: onViewportStartChanged
        )
        .help("Use trackpad/mouse scrolling for native pan and momentum")
    }
}

private final class TimelineScrollerContentView: NSView {}

private final class TimelineScrollerCoordinator: NSObject {
    var suppressCallback = false
    var onViewportStartChanged: (Double) -> Void
    var maxViewportStartSeconds: Double = 0
    weak var clipView: NSClipView?
    weak var contentView: NSView?

    init(onViewportStartChanged: @escaping (Double) -> Void) {
        self.onViewportStartChanged = onViewportStartChanged
    }

    @objc func boundsChanged(_ notification: Notification) {
        guard !suppressCallback,
              let clipView,
              let contentView else { return }

        let contentWidth = max(1, contentView.frame.width)
        let visibleWidth = max(1, clipView.bounds.width)
        let maxOffset = max(0, contentWidth - visibleWidth)
        guard maxOffset > 0 else { return }

        let ratio = min(max(0, Double(clipView.bounds.origin.x / maxOffset)), 1.0)
        onViewportStartChanged(ratio * maxViewportStartSeconds)
    }
}

private struct NativeTimelineScroller: NSViewRepresentable {
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let onViewportStartChanged: (Double) -> Void

    func makeCoordinator() -> TimelineScrollerCoordinator {
        TimelineScrollerCoordinator(onViewportStartChanged: onViewportStartChanged)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.scrollerStyle = .legacy

        let content = TimelineScrollerContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.documentView = content

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(TimelineScrollerCoordinator.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )

        context.coordinator.clipView = clipView
        context.coordinator.contentView = content
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onViewportStartChanged = onViewportStartChanged
        guard let content = nsView.documentView else { return }

        let visibleDuration = max(0.0001, visibleEndSeconds - visibleStartSeconds)
        let totalDuration = max(0.0001, totalDurationSeconds)
        let viewportRatio = min(1.0, visibleDuration / totalDuration)
        let viewportWidth = max(1, nsView.contentSize.width)

        // Use proportional content width so native scroller knob maps 1:1 with viewport range.
        let contentWidth = max(viewportWidth, viewportWidth / max(viewportRatio, 0.0001))
        if abs(content.frame.width - contentWidth) > 0.5 {
            content.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 1)
        }

        let maxViewportStart = max(0.0, totalDuration - visibleDuration)
        context.coordinator.maxViewportStartSeconds = maxViewportStart
        let maxOffset = max(0.0, contentWidth - viewportWidth)
        let targetOffset: CGFloat
        if maxViewportStart > 0, maxOffset > 0 {
            let ratio = min(max(0, visibleStartSeconds / maxViewportStart), 1.0)
            targetOffset = CGFloat(ratio) * maxOffset
        } else {
            targetOffset = 0
        }

        if abs(nsView.contentView.bounds.origin.x - targetOffset) > 0.5 {
            context.coordinator.suppressCallback = true
            nsView.contentView.bounds.origin.x = targetOffset
            nsView.reflectScrolledClipView(nsView.contentView)
            context.coordinator.suppressCallback = false
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: TimelineScrollerCoordinator) {
        if let clipView = coordinator.clipView {
            NotificationCenter.default.removeObserver(
                coordinator,
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }
    }
}

struct InspectToolView: View {
    let sourceURL: URL?
    let analysis: FileAnalysis?
    let sourceInfo: SourceMediaInfo?
    let transcriptSegments: [TranscriptSegment]
    let transcriptStatusText: String
    let canGenerateTranscript: Bool
    let isGeneratingTranscript: Bool
    let whisperTranscriptionAvailable: Bool
    let hasAudioTrack: Bool
    let generateTranscript: () -> Void
    let exportTranscriptTXT: () -> Void
    let isCompactLayout: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var transcriptSearchText = ""
    @State private var transcriptFontSize: CGFloat = 14

    private var filteredTranscriptSegments: [TranscriptSegment] {
        let query = transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return transcriptSegments }
        return transcriptSegments.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private func fileIcon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sourceURL {
                GroupBox("File") {
                    HStack(alignment: .top, spacing: 12) {
                        Image(nsImage: fileIcon(for: sourceURL))
                            .interpolation(.high)
                            .frame(width: 64, height: 64, alignment: .topLeading)
                            .onDrag {
                                NSItemProvider(contentsOf: sourceURL) ?? NSItemProvider()
                            }
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                                }
                                Button("Copy Path") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(sourceURL.path, forType: .string)
                                }
                            }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(sourceURL.lastPathComponent)
                                    .font(.headline)
                                Spacer()
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Text(sourceURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        adaptiveContainerFill(
                            material: .thinMaterial,
                            fallback: Color(nsColor: .controlBackgroundColor),
                            reduceTransparency: reduceTransparency
                        ),
                        in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    )
                }

                GroupBox("Video") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Codec: \(sourceInfo?.videoCodec ?? "—")")
                        Text("Resolution: \(sourceInfo?.resolution ?? "—")")
                        Text("Frame rate: \(sourceInfo?.frameRate.map { String(format: "%.2f fps", $0) } ?? "—")")
                        Text("Video bitrate: \(formatBitrate(sourceInfo?.videoBitrateBps))")
                        Text("Color primaries: \(sourceInfo?.colorPrimaries ?? "—")")
                        Text("Transfer function: \(sourceInfo?.colorTransfer ?? "—")")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        adaptiveContainerFill(
                            material: .thinMaterial,
                            fallback: Color(nsColor: .controlBackgroundColor),
                            reduceTransparency: reduceTransparency
                        ),
                        in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    )
                }

                GroupBox("Audio") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Audio codec: \(sourceInfo?.audioCodec ?? "—")")
                        Text("Sample rate: \(sourceInfo?.sampleRateHz.map { String(format: "%.0f Hz", $0) } ?? "—")")
                        Text("Channels: \(sourceInfo?.channels.map(String.init) ?? "—")")
                        Text("Audio bitrate: \(formatBitrate(sourceInfo?.audioBitrateBps))")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        adaptiveContainerFill(
                            material: .thinMaterial,
                            fallback: Color(nsColor: .controlBackgroundColor),
                            reduceTransparency: reduceTransparency
                        ),
                        in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    )
                }

                GroupBox("Container") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Duration: \(sourceInfo?.durationSeconds.map(formatSeconds) ?? "—")")
                        Text("Overall bitrate: \(formatBitrate(sourceInfo?.overallBitrateBps))")
                        Text("File size: \(formatFileSize(sourceInfo?.fileSizeBytes))")
                        Text("Container: \(sourceInfo?.containerDescription ?? "—")")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(
                        adaptiveContainerFill(
                            material: .thinMaterial,
                            fallback: Color(nsColor: .controlBackgroundColor),
                            reduceTransparency: reduceTransparency
                        ),
                        in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    )
                }

                GroupBox("Transcript") {
                    VStack(alignment: .leading, spacing: 8) {
                        if transcriptSegments.isEmpty {
                            Text(transcriptStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if !whisperTranscriptionAvailable {
                                Text("Whisper binary/model is not available in this app bundle.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if !hasAudioTrack {
                                Text("No audio track available.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Button(isGeneratingTranscript ? "Generating Transcript…" : "Generate Transcript") {
                                generateTranscript()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!canGenerateTranscript || isGeneratingTranscript)
                        } else {
                            HStack(spacing: 8) {
                                TextField("Search transcript", text: $transcriptSearchText)
                                    .textFieldStyle(.roundedBorder)

                                HStack(spacing: 4) {
                                    Button {
                                        transcriptFontSize = max(11, transcriptFontSize - 1)
                                    } label: {
                                        Image(systemName: "textformat.size.smaller")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button {
                                        transcriptFontSize = min(24, transcriptFontSize + 1)
                                    } label: {
                                        Image(systemName: "textformat.size.larger")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }

                                Button("Export TXT") {
                                    exportTranscriptTXT()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Text(transcriptStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(filteredTranscriptSegments) { segment in
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(formatSeconds(segment.start))
                                                .font(.system(size: max(11, transcriptFontSize - 1), weight: .regular, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
                                                .frame(width: 112, alignment: .leading)
                                            Text(segment.text)
                                                .font(.system(size: transcriptFontSize))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                            }
                            .frame(minHeight: 120, maxHeight: 220)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        adaptiveContainerFill(
                            material: .thinMaterial,
                            fallback: Color(nsColor: .controlBackgroundColor),
                            reduceTransparency: reduceTransparency
                        ),
                        in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    )
                }
            } else {
                EmptyToolView(title: "Inspect", subtitle: "Choose source media to inspect metadata and results.")
            }

            if !isCompactLayout {
                Spacer()
            }
        }
    }
}

struct StatusFooterStripView: View {
    @ObservedObject var model: WorkspaceViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var stateColor: Color {
        switch model.lastActivityState {
        case .idle:
            return .secondary
        case .running:
            return .accentColor
        case .success:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }

    @ViewBuilder
    private var stateIconView: some View {
        if #available(macOS 14.0, *), !reduceMotion {
            Image(systemName: model.lastResultIconName)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, options: model.isActivityRunning ? .repeating : .default, value: model.isActivityRunning)
        } else {
            Image(systemName: model.lastResultIconName)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    stateIconView
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(stateColor)
                        .frame(width: 20, height: 20, alignment: .center)
                    Text(model.lastResultLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .frame(width: 140, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.activityText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    ProgressView(value: model.activityProgress ?? 0)
                        .progressViewStyle(.linear)
                        .opacity(model.activityProgress == nil ? 0.35 : 1.0)
                }

                HStack(spacing: 8) {
                    Group {
                        if model.isActivityRunning {
                            Button(role: .destructive) {
                                model.stopCurrentActivity()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .buttonStyle(.bordered)
                        } else if model.outputURL != nil {
                            Button("Show in Finder") {
                                model.revealOutput()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .trailing)))

                    Button(model.showActivityConsole ? "Hide Console" : "Console") {
                        model.showActivityConsole.toggle()
                    }
                    .buttonStyle(.bordered)

                    if model.showActivityConsole {
                        Button("Copy") {
                            model.copyActivityConsole()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.activityConsoleText.isEmpty)

                        Button("Clear") {
                            model.clearActivityConsole()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.activityConsoleText.isEmpty)
                    }
                }
            }

            if model.showActivityConsole {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.activityConsoleText.isEmpty ? "Console output will appear here while tools run." : model.activityConsoleText)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear
                                .frame(height: 1)
                                .id("console-end")
                        }
                    }
                    .frame(minHeight: 90, maxHeight: 150)
                    .padding(8)
                    .background(
                        adaptiveContainerFill(
                            material: .thinMaterial,
                            fallback: Color(nsColor: .controlBackgroundColor),
                            reduceTransparency: reduceTransparency
                        ),
                        in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .onChange(of: model.activityConsoleText) { _ in
                        guard model.showActivityConsole else { return }
                        if reduceMotion {
                            proxy.scrollTo("console-end", anchor: .bottom)
                        } else {
                            withAnimation(.linear(duration: 0.1)) {
                                proxy.scrollTo("console-end", anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        proxy.scrollTo("console-end", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            adaptiveContainerFill(
                material: .regularMaterial,
                fallback: Color(nsColor: .windowBackgroundColor),
                reduceTransparency: reduceTransparency
            ),
            in: RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.lastActivityState)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.isActivityRunning)
    }
}

struct SegmentTimelineView: View {
    let blackSegments: [Segment]
    let silentSegments: [Segment]
    let profanitySegments: [Segment]
    let showBlackLane: Bool
    let showSilentLane: Bool
    let showProfanityLane: Bool
    let duration: Double

    @ViewBuilder
    private func lane(label: String, segments: [Segment], color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .fill(Color.gray.opacity(0.18))
                        .frame(height: 12)

                    ForEach(segments) { segment in
                        let safeDuration = max(duration, 0.001)
                        let startRatio = max(0, min(1, segment.start / safeDuration))
                        let widthRatio = max(0, min(1 - startRatio, segment.duration / safeDuration))
                        let x = geometry.size.width * startRatio
                        let w = max(2, geometry.size.width * widthRatio)

                        RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                            .fill(color)
                            .frame(width: w, height: 12)
                            .offset(x: x)
                    }
                }
            }
            .frame(height: 12)
        }
    }

    var body: some View {
        let hasVisibleLane = showBlackLane || showSilentLane || showProfanityLane

        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                if showBlackLane {
                    lane(label: "Black", segments: blackSegments, color: Color.black.opacity(0.9))
                }
                if showSilentLane {
                    lane(label: "Silence", segments: silentSegments, color: Color.orange.opacity(0.85))
                }
                if showProfanityLane {
                    lane(label: "Profanity", segments: profanitySegments, color: Color.red.opacity(0.9))
                }
            }

            if hasVisibleLane {
                HStack {
                    Text("00:00:00.000")
                        .padding(.leading, 72)
                    Spacer()
                    Text(formatSeconds(duration))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text("Run analysis to populate timeline lanes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct InlinePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

struct DetailView: View {
    let file: FileAnalysis
    let isCompactLayout: Bool
    @ObservedObject var model: WorkspaceViewModel

    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var hoveredBlackSegmentID: UUID?
    @State private var hoveredSilentSegmentID: UUID?
    @State private var hoveredProfanityHitID: UUID?

    private func loadPlayerItem() {
        let item = AVPlayerItem(url: file.fileURL)
        player.replaceCurrentItem(with: item)
        isPlaying = false
    }

    private func play(from time: Double) {
        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPlaying = true
    }

    private func jump(by seconds: Double) {
        let current = CMTimeGetSeconds(player.currentTime())
        let duration = CMTimeGetSeconds(player.currentItem?.duration ?? .invalid)
        let maxTime = (duration.isFinite && duration > 0) ? duration : max(0, current + seconds)
        let target = min(max(0, current + seconds), maxTime)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    @ViewBuilder
    private func analysisSections(showCopyButtons: Bool, showEmptySections: Bool = false) -> some View {
        let analysisHasRunOrIsRunning: Bool = {
            switch file.status {
            case .running, .done:
                return true
            case .idle, .failed:
                return false
            }
        }()

        if let timelineDuration = file.timelineDuration {
            SegmentTimelineView(
                blackSegments: file.includedBlackDetection ? file.segments : [],
                silentSegments: file.includedSilenceDetection ? file.silentSegments : [],
                profanitySegments: file.includedProfanityDetection ? file.profanityHits.map { Segment(start: $0.start, end: $0.end, duration: $0.duration) } : [],
                showBlackLane: analysisHasRunOrIsRunning && file.includedBlackDetection,
                showSilentLane: analysisHasRunOrIsRunning && file.includedSilenceDetection,
                showProfanityLane: analysisHasRunOrIsRunning && file.includedProfanityDetection,
                duration: timelineDuration
            )
        }

        if file.includedBlackDetection && (showEmptySections || !file.segments.isEmpty) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Black Segments")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if showCopyButtons {
                        Button("Copy Black List") {
                            copyToClipboard(file.formattedList)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if file.segments.isEmpty {
                    Text("No black segments detected yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(file.segments) { segment in
                                HStack {
                                    Text(formatSeconds(segment.start))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                    Text("→")
                                        .foregroundStyle(.secondary)
                                    Text(formatSeconds(segment.end))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                    Spacer()
                                    Text(String(format: "%.3fs", segment.duration))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                        .fill(hoveredBlackSegmentID == segment.id ? Color.accentColor.opacity(0.16) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                        .stroke(
                                            hoveredBlackSegmentID == segment.id ? Color.accentColor.opacity(0.26) : Color.primary.opacity(0.045),
                                            lineWidth: hoveredBlackSegmentID == segment.id ? 0.9 : 0.4
                                        )
                                )
                                .contentShape(Rectangle())
                                .onHover { isHovering in
                                    hoveredBlackSegmentID = isHovering ? segment.id : (hoveredBlackSegmentID == segment.id ? nil : hoveredBlackSegmentID)
                                }
                                .onTapGesture(count: 2) {
                                    play(from: segment.start)
                                }
                                .help("Double-click to play from this segment start")
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }

        if file.includedSilenceDetection && (showEmptySections || !file.silentSegments.isEmpty) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Silent Gaps (> \(String(format: "%.1f", file.silenceMinDurationSeconds))s)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if showCopyButtons {
                        Button("Copy Silence List") {
                            copyToClipboard(file.formattedSilentList)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if file.silentSegments.isEmpty {
                    Text("No silent gaps detected yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(file.silentSegments) { segment in
                                HStack {
                                    Text(formatSeconds(segment.start))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                    Text("→")
                                        .foregroundStyle(.secondary)
                                    Text(formatSeconds(segment.end))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                    Spacer()
                                    Text(String(format: "%.3fs", segment.duration))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                        .fill(hoveredSilentSegmentID == segment.id ? Color.accentColor.opacity(0.16) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                        .stroke(
                                            hoveredSilentSegmentID == segment.id ? Color.accentColor.opacity(0.26) : Color.primary.opacity(0.045),
                                            lineWidth: hoveredSilentSegmentID == segment.id ? 0.9 : 0.4
                                        )
                                )
                                .contentShape(Rectangle())
                                .onHover { isHovering in
                                    hoveredSilentSegmentID = isHovering ? segment.id : (hoveredSilentSegmentID == segment.id ? nil : hoveredSilentSegmentID)
                                }
                                .onTapGesture(count: 2) {
                                    play(from: segment.start)
                                }
                                .help("Double-click to play from this silent-gap start")
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }

        if file.includedProfanityDetection && (showEmptySections || !file.profanityHits.isEmpty) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Profanity Hits")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if showCopyButtons {
                        Button("Copy Profanity List") {
                            copyToClipboard(file.formattedProfanityList)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if file.profanityHits.isEmpty {
                    Text("No profanity detected yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(file.profanityHits) { hit in
                                HStack {
                                    Text(formatSeconds(hit.start))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                    Text("→")
                                        .foregroundStyle(.secondary)
                                    Text(formatSeconds(hit.end))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                    Spacer()
                                    Text(hit.word)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                        .fill(hoveredProfanityHitID == hit.id ? Color.accentColor.opacity(0.16) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                        .stroke(
                                            hoveredProfanityHitID == hit.id ? Color.accentColor.opacity(0.26) : Color.primary.opacity(0.045),
                                            lineWidth: hoveredProfanityHitID == hit.id ? 0.9 : 0.4
                                        )
                                )
                                .contentShape(Rectangle())
                                .onHover { isHovering in
                                    hoveredProfanityHitID = isHovering ? hit.id : (hoveredProfanityHitID == hit.id ? nil : hoveredProfanityHitID)
                                }
                                .onTapGesture(count: 2) {
                                    play(from: hit.start)
                                }
                                .help("Double-click to play from this profanity hit")
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(file.fileURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if model.hasVideoTrack {
                InlinePlayerView(player: player)
                    .frame(
                        minHeight: isCompactLayout ? 150 : 260,
                        maxHeight: isCompactLayout ? 210 : 320
                    )
                    .clipShape(RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                    Text("Audio-only source")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous))
            }

            HStack {
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        jump(by: -Double(model.jumpIntervalSeconds))
                    } label: {
                        Label("Back \(model.jumpIntervalSeconds)s", systemImage: "gobackward")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        togglePlayPause()
                    } label: {
                        Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        jump(by: Double(model.jumpIntervalSeconds))
                    } label: {
                        Label("Forward \(model.jumpIntervalSeconds)s", systemImage: "goforward")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                Spacer()
            }

            switch file.status {
            case .running:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(model.analyzeStatusText.isEmpty ? "Preparing analysis…" : model.analyzeStatusText)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Spacer()
                    }

                    if !file.segments.isEmpty || !file.silentSegments.isEmpty || !file.profanityHits.isEmpty {
                        Text("Detections so far")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        if !file.segments.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Black segments: \(file.segments.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(Array(file.segments.suffix(8))) { segment in
                                    Text(segment.formatted)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if !file.silentSegments.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Silent gaps: \(file.silentSegments.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(Array(file.silentSegments.suffix(8))) { segment in
                                    Text(segment.formatted)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if !file.profanityHits.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Profanity hits: \(file.profanityHits.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(Array(file.profanityHits.suffix(8))) { hit in
                                    Text(hit.formatted)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                analysisSections(showCopyButtons: false, showEmptySections: true)
            case .failed(let reason):
                Text("Analysis failed: \(reason)")
                    .foregroundStyle(.red)
            case .idle:
                Text("Ready to analyze")
                    .foregroundStyle(.secondary)
            case .done:
                VStack(alignment: .leading, spacing: 4) {
                    if file.includedBlackDetection {
                        if file.segments.isEmpty {
                            Label("No black segments detected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Black segments detected: \(file.segments.count)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    if file.includedSilenceDetection {
                        if file.silentSegments.isEmpty {
                            Label("No silent gaps detected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Silent gaps detected: \(file.silentSegments.count)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    if file.includedProfanityDetection {
                        if file.profanityHits.isEmpty {
                            Label("No profanity detected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Profanity hits detected: \(file.profanityHits.count)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                analysisSections(showCopyButtons: true)
            }

            Spacer()
        }
        .padding(16)
        .onAppear {
            loadPlayerItem()
        }
        .onChange(of: file.fileURL.path) { _ in
            loadPlayerItem()
        }
        .onDisappear {
            player.pause()
        }
    }
}

struct EmptyToolView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            onResolve(window)
        }
    }
}

struct ContentView: View {
    @StateObject private var model: WorkspaceViewModel
    @ObservedObject private var externalOpenBridge = ExternalFileOpenBridge.shared
    @State private var isDropTargeted = false
    @State private var appWindow: NSWindow?

    @MainActor init() {
        _model = StateObject(wrappedValue: WorkspaceViewModel())
    }

    private func syncWindowMetadata() {
        guard let appWindow else { return }
        appWindow.titleVisibility = .visible
        appWindow.titlebarAppearsTransparent = false
        appWindow.title = model.sourceURL?.lastPathComponent ?? "Bulwark Video Tools"
        appWindow.subtitle = ""
        appWindow.representedURL = model.sourceURL
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompactLayout = proxy.size.height < 760
            let contentPadding = isCompactLayout ? 8.0 : 12.0

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: isCompactLayout ? 8 : 10) {
                    SourceHeaderView(model: model)

                    ToolContentView(model: model, isCompactLayout: isCompactLayout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.top, contentPadding)
                .padding(.horizontal, contentPadding)
                .padding(.bottom, contentPadding)

                StatusFooterStripView(model: model)
                    .padding(.horizontal, 0)
                    .padding(.bottom, contentPadding / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
                model.handleDrop(providers: providers)
            }
            .onOpenURL { url in
                guard url.isFileURL else { return }
                model.setSource(url)
                NSApp.activate(ignoringOtherApps: true)
            }
            .onReceive(externalOpenBridge.$incomingURL) { url in
                guard let url else { return }
                guard appWindow?.isKeyWindow == true else { return }
                model.setSource(url)
                NSApp.activate(ignoringOtherApps: true)
                externalOpenBridge.incomingURL = nil
            }
        }
        .preferredColorScheme(model.appearance.colorScheme)
        .frame(minWidth: 980, minHeight: 640)
        .background(
            WindowAccessor { window in
                appWindow = window
                syncWindowMetadata()
            }
        )
        .onChange(of: model.sourceURL?.path) { _ in
            syncWindowMetadata()
        }
        .focusedSceneValue(\.workspaceModel, model)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.chooseSource()
                } label: {
                    Label(model.sourceURL == nil ? "Choose Media" : "Change Media", systemImage: "video.badge.plus")
                }
            }
        }
    }
}
