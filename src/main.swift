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
    static let clipJumpToStart = Notification.Name("clipJumpToStart")
    static let clipJumpToEnd = Notification.Name("clipJumpToEnd")
    static let clipCaptureFrame = Notification.Name("clipCaptureFrame")
}

private let minDurationSeconds = 0.001
private let defaultMinSilenceDurationSeconds = 1.0
private let silenceAmplitudeThreshold = 0.01
private let defaultAdvancedClipFilenameTemplate = "{source_name}_clip_{in_tc}_to_{out_tc}"
private let defaultProfanityWords: Set<String> = [
    "ass", "asshole", "bastard", "bitch", "bullshit", "crap", "damn",
    "dick", "douche", "douchebag", "fucker", "fucking", "fuck", "goddamn",
    "hell", "motherfucker", "pissed", "shit", "shitty", "slut", "whore"
]
private let defaultProfanityWordsStorageString = defaultProfanityWords.sorted().joined(separator: ", ")
private let picThreshold = 0.90
private let pixelBlackThreshold = 0.10
private let maxSampleDimension = 640
private enum UIRadius {
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
    silenceMinDuration: Double = defaultMinSilenceDurationSeconds,
    onStatusUpdate: @escaping @Sendable (String) -> Void = { _ in },
    onBlackSegmentDetected: @escaping @Sendable (Segment) -> Void = { _ in },
    onSilentSegmentDetected: @escaping @Sendable (Segment) -> Void = { _ in },
    onProfanityDetected: @escaping @Sendable (ProfanityHit) -> Void = { _ in },
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
        onStatusUpdate("Transcribing audio for profanity")
        let profanityBase = (detectAudioSilence || detectBlackFrames) ? 0.70 : 0.0
        let profanitySpan = (detectAudioSilence || detectBlackFrames) ? 0.29 : 0.99
        let profanityResult = detectProfanityHits(
            file: file,
            profanityWords: profanityWords,
            shouldCancel: {
                shouldCancel()
            },
            progressHandler: { profanityProgress in
                let clamped = min(1, max(0, profanityProgress))
                progressHandler(min(0.99, profanityBase + (clamped * profanitySpan)))
            }
        )
        switch profanityResult {
        case .success(let hits):
            profanityHits = hits
            hits.forEach { onProfanityDetected($0) }
        case .failure(let error):
            return .failure(error)
        }
    }

    progressHandler(1.0)
    return .success(DetectionOutput(segments: segments, silentSegments: silentSegments, profanityHits: profanityHits, mediaDuration: outputDuration))
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

private func normalizedToken(_ token: String) -> String {
    token
        .trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines))
        .lowercased()
}

private func profanityWordsFromString(_ raw: String) -> Set<String> {
    let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
    return Set(
        raw.components(separatedBy: separators)
            .map(normalizedToken)
            .filter { !$0.isEmpty }
    )
}

private func normalizedProfanityWordsStorageString(_ raw: String) -> String {
    profanityWordsFromString(raw).sorted().joined(separator: ", ")
}

private func sanitizeFilenameComponent(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
    let sanitizedScalars = value.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) }
    let sanitized = String(sanitizedScalars)
        .replacingOccurrences(of: "\n", with: "_")
        .replacingOccurrences(of: "\r", with: "_")
    return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func extractPercentProgress(from line: String) -> Double? {
    let pattern = #"([0-9]{1,3})(?:\.[0-9]+)?\s*%"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    guard let match = regex.firstMatch(in: line, range: range),
          let percentRange = Range(match.range(at: 1), in: line),
          let percent = Double(line[percentRange]) else { return nil }
    return min(max(percent / 100.0, 0.0), 1.0)
}

private func findWhisperExecutable() -> URL? {
    if let bundled = Bundle.main.url(forResource: "whisper-cli", withExtension: nil),
       FileManager.default.isExecutableFile(atPath: bundled.path) {
        return bundled
    }
    return nil
}

private func findWhisperModel() -> URL? {
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
    shouldCancel: @escaping @Sendable () -> Bool
) -> Result<(stdout: String, stderr: String), DetectionError> {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        return .failure(.failed("Failed to run \(executableURL.lastPathComponent): \(error.localizedDescription)"))
    }

    while process.isRunning {
        if shouldCancel() {
            process.terminate()
            return .failure(.cancelled)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
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
    progressHandler: @escaping @Sendable (Double) -> Void
) -> Result<(stdout: String, stderr: String), DetectionError> {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    var stdoutData = Data()
    var stderrData = Data()
    let lock = NSLock()

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        if let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if let progress = extractPercentProgress(from: String(line)) {
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

private func detectProfanityFromTranscriptionJSON(_ jsonData: Data, profanityWords: Set<String>) -> [ProfanityHit] {
    guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        return []
    }

    var hits: [ProfanityHit] = []
    let transcription = object["transcription"] as? [[String: Any]] ?? object["segments"] as? [[String: Any]] ?? []
    for segment in transcription {
        let text = (segment["text"] as? String ?? "")
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map { normalizedToken(String($0)) }
        let matchedWords = tokens.filter { profanityWords.contains($0) }
        if matchedWords.isEmpty { continue }

        let startMs: Double? = ((segment["offsets"] as? [String: Any])?["from"] as? Double)
        let endMs: Double? = ((segment["offsets"] as? [String: Any])?["to"] as? Double)
        let startSecAlt = segment["start"] as? Double
        let endSecAlt = segment["end"] as? Double

        let start = max(0, (startMs ?? (startSecAlt ?? 0)) / (startMs != nil ? 1000.0 : 1.0))
        let endRaw = (endMs ?? (endSecAlt ?? (start + 0.2))) / (endMs != nil ? 1000.0 : 1.0)
        let end = max(start + 0.05, endRaw)
        let duration = end - start

        for word in matchedWords {
            hits.append(ProfanityHit(start: start, end: end, duration: duration, word: word))
        }
    }

    hits.sort { lhs, rhs in
        if abs(lhs.start - rhs.start) > 0.0001 { return lhs.start < rhs.start }
        return lhs.word < rhs.word
    }
    return hits
}

func detectProfanityHits(
    file: URL,
    profanityWords: Set<String>,
    shouldCancel: @escaping @Sendable () -> Bool = { false },
    progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
) -> Result<[ProfanityHit], DetectionError> {
    if shouldCancel() {
        return .failure(.cancelled)
    }

    guard let ffmpegURL = findSystemFFmpegExecutable() else {
        return .failure(.failed("No ffmpeg executable found for profanity transcription."))
    }
    guard let whisperURL = findWhisperExecutable() else {
        return .failure(.failed("Bundled whisper-cli not found (Contents/Resources/whisper-cli)."))
    }
    guard let modelURL = findWhisperModel() else {
        return .failure(.failed("Bundled Whisper model not found (Contents/Resources/profanity-model.bin)."))
    }

    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("bvt-profanity-\(UUID().uuidString)", isDirectory: true)
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
        shouldCancel: shouldCancel
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
        progressHandler: progressHandler
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
            progressHandler: progressHandler
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

    return .success(detectProfanityFromTranscriptionJSON(jsonData, profanityWords: profanityWords))
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
    }

    @Published var selectedTool: WorkspaceTool = .clip
    @Published var sourceURL: URL?
    @Published var sourceSessionID = UUID()
    @Published var analysis: FileAnalysis?
    @Published var sourceInfo: SourceMediaInfo?

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

    @Published var clipStartSeconds: Double = 0
    @Published var clipEndSeconds: Double = 0
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

    @Published var uiMessage = "Ready"
    @Published var lastActivityState: ActivityState = .idle

    private var analyzeTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
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
    }

    var canAnalyze: Bool {
        sourceURL != nil && !isAnalyzing && !isExporting && (effectiveAnalyzeBlackFrames || effectiveAnalyzeAudioSilence || effectiveAnalyzeProfanity)
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
        sourceURL != nil && !isAnalyzing && !isExporting
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
        clipEncodingMode = hasVideoTrack ? defaultClipEncodingMode : .audioOnly
        applySuggestedClipBitrateFromSource()
        outputURL = nil
        uiMessage = "Loaded \(url.lastPathComponent)"
        wasCancelled = false
        analyzeProgress = 0
        exportProgress = 0
        captureTimelineMarkers = []
        highlightedCaptureTimelineMarkerID = nil
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
        waveformCache.removeAll(keepingCapacity: false)
        waveformCacheOrder.removeAll(keepingCapacity: false)
        outputURL = nil
        captureTimelineMarkers = []
        highlightedCaptureTimelineMarkerID = nil
        uiMessage = "Ready"
        resetClipRange()
    }

    func stopCurrentActivity() {
        if isAnalyzing {
            stopAnalysis()
            return
        }
        if isExporting {
            stopExport()
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
            let hybridSeekPreRoll = 0.75
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
                    let escapedPath = self.escapeSubtitlesFilterPath(prepared.srtURL.path)
                    videoFilters.append("subtitles='\(escapedPath)'")
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
        let clampedTime = max(0, min(seconds, duration > 0 ? duration : seconds))
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
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0 / 120.0, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0 / 120.0, preferredTimescale: 600)

            let cgImage = try generator.copyCGImage(
                at: CMTime(seconds: clampedTime, preferredTimescale: 600),
                actualTime: nil
            )
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                uiMessage = "Frame capture failed: Unable to encode PNG."
                lastActivityState = .failed
                return
            }

            try pngData.write(to: destinationURL, options: .atomic)
            outputURL = destinationURL
            addCaptureTimelineMarker(at: clampedTime)
            uiMessage = "Frame saved: \(destinationURL.lastPathComponent)"
            lastActivityState = .success
            playFrameCaptureSound()
        } catch {
            uiMessage = "Frame capture failed: \(error.localizedDescription)"
            lastActivityState = .failed
        }
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
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard let self, self.highlightedCaptureTimelineMarkerID == markerID else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                self.highlightedCaptureTimelineMarkerID = nil
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
                                        Text(formatFileSize(model.estimatedAudioExportSizeBytes))
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(.secondary)
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

    @State private var player = AVPlayer()
    @State private var playheadSeconds: Double = 0
    @State private var playerDurationSeconds: Double = 0
    @State private var waveformSamples: [Double] = []
    @State private var isWaveformLoading = false
    @State private var waveformTask: Task<Void, Never>?
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var mouseDownMonitor: Any?
    @State private var timelineZoom: Double = 1.0
    @State private var viewportStartSeconds: Double = 0
    @State private var isViewportManuallyControlled = false
    @State private var isTimelineHovered = false
    @State private var timelineInteractiveWidth: CGFloat = 1

    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var fastClipFormats: [ClipFormat] { [.mp4, .mov] }
    private var advancedClipFormats: [ClipFormat] { ClipFormat.allCases }

    private func loadPlayerItem() {
        guard let sourceURL = model.sourceURL else {
            player.replaceCurrentItem(with: nil)
            playheadSeconds = 0
            playerDurationSeconds = 0
            waveformTask?.cancel()
            waveformSamples = []
            isWaveformLoading = false
            return
        }
        let item = AVPlayerItem(url: sourceURL)
        player.replaceCurrentItem(with: item)
        let duration = CMTimeGetSeconds(item.asset.duration)
        playerDurationSeconds = duration.isFinite && duration > 0 ? duration : model.sourceDurationSeconds
        playheadSeconds = 0
        viewportStartSeconds = 0
        loadWaveform(for: sourceURL)
    }

    private func loadWaveform(for url: URL) {
        waveformTask?.cancel()

        let targetSampleCount = Int(min(24_000, max(4_000, model.sourceDurationSeconds * 40.0)))

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
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playheadSeconds = clamped
        updateViewportForPlayhead(shouldFollow: !isViewportManuallyControlled || player.rate != 0)
    }

    private func seekPlayerAndFocusViewport(to time: Double) {
        let clamped = max(0, min(time, max(playerDurationSeconds, model.sourceDurationSeconds)))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playheadSeconds = clamped

        if timelineZoom > 1 {
            viewportStartSeconds = clampedViewportStart(clamped - (zoomedWindowDuration / 2.0))
            isViewportManuallyControlled = true
        } else {
            updateViewportForPlayhead(shouldFollow: true)
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

    private func clampedViewportStart(_ start: Double) -> Double {
        let maxStart = max(0, totalDurationSeconds - zoomedWindowDuration)
        return min(max(0, start), maxStart)
    }

    private func updateViewportForPlayhead(shouldFollow: Bool) {
        if timelineZoom <= 1 {
            viewportStartSeconds = 0
            isViewportManuallyControlled = false
            return
        }

        let window = zoomedWindowDuration
        var start = clampedViewportStart(viewportStartSeconds)
        guard shouldFollow else {
            viewportStartSeconds = start
            return
        }

        let end = start + window
        if playheadSeconds < start || playheadSeconds > end {
            viewportStartSeconds = clampedViewportStart(playheadSeconds - (window / 2))
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
        viewportStartSeconds = clampedViewportStart(viewportStartSeconds - (Double(points) * secondsPerPoint))
        isViewportManuallyControlled = true
    }

    private func adjustTimelineZoom(by delta: Double) {
        let newZoom = min(100, max(1, timelineZoom + delta))
        guard newZoom != timelineZoom else { return }
        timelineZoom = newZoom
        updateViewportForPlayhead(shouldFollow: false)
    }

    private func resetTimelineZoom() {
        guard timelineZoom != 1 else { return }
        timelineZoom = 1
        updateViewportForPlayhead(shouldFollow: false)
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
            if NSApp.keyWindow?.firstResponder is NSTextView {
                return event
            }

            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasDisallowedModifier = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)

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
                if event.specialKey == .upArrow {
                    seekPlayerAndFocusViewport(to: model.clipStartSeconds)
                    return nil
                }
                if event.specialKey == .downArrow {
                    seekPlayerAndFocusViewport(to: model.clipEndSeconds)
                    return nil
                }
            }

            if flags.isDisjoint(with: [.command, .option, .control]) && !flags.contains(.shift) {
                if chars == "i" {
                    model.setClipStart(playheadSeconds)
                    return nil
                }
                if chars == "o" {
                    model.setClipEnd(playheadSeconds)
                    return nil
                }
                if chars == "x" {
                    model.resetClipRange()
                    seekPlayer(to: model.clipStartSeconds)
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

    private func installMouseDownMonitor() {
        guard mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
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
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
    }

    private func dismissTimecodeFieldFocus() {
        model.commitClipStartText()
        model.commitClipEndText()
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.sourceURL != nil {
                InlinePlayerView(player: player)
                    .frame(
                        minHeight: isCompactLayout ? 150 : 260,
                        maxHeight: isCompactLayout ? 210 : 320
                    )
                    .clipShape(RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous))
                    .onTapGesture {
                        dismissTimecodeFieldFocus()
                    }

                GroupBox("Timeline Controls") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Zoom")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $timelineZoom, in: 1...100, step: 1)
                            Text("\(Int(timelineZoom.rounded()))x")
                                .font(.caption.monospacedDigit())
                                .frame(width: 48, alignment: .trailing)
                            Button("Fit") {
                                timelineZoom = 1
                            }
                            .buttonStyle(.bordered)
                        }

                        if timelineZoom > 1 {
                            TimelineViewportScroller(
                                totalDurationSeconds: totalDurationSeconds,
                                visibleStartSeconds: visibleStartSeconds,
                                visibleEndSeconds: visibleEndSeconds
                            ) { newStart in
                                viewportStartSeconds = clampedViewportStart(newStart)
                                isViewportManuallyControlled = true
                            }
                            .frame(height: 14)

                            HStack(spacing: 6) {
                                Image(systemName: "hand.draw")
                                Text("Drag viewport or use trackpad scroll to pan")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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

                GroupBox("Selection") {
                    VStack(alignment: .leading, spacing: 10) {
                        if !isCompactLayout && isWaveformLoading {
                            HStack {
                                ProgressView()
                                Text("Generating waveform…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if !isCompactLayout && !waveformSamples.isEmpty {
                            WaveformView(
                                samples: waveformSamples,
                                startSeconds: model.clipStartSeconds,
                                playheadSeconds: playheadSeconds,
                                endSeconds: model.clipEndSeconds,
                                totalDurationSeconds: totalDurationSeconds,
                                visibleStartSeconds: visibleStartSeconds,
                                visibleEndSeconds: visibleEndSeconds,
                                captureMarkers: model.captureTimelineMarkers,
                                highlightedMarkerID: model.highlightedCaptureTimelineMarkerID,
                                onSeek: { seekPlayer(to: $0) }
                            )
                            .frame(height: 58)
                        }

                        UnifiedClipTimelineSelector(
                            startSeconds: Binding(
                                get: { model.clipStartSeconds },
                                set: {
                                    model.setClipStart($0)
                                }
                            ),
                            playheadSeconds: Binding(
                                get: { playheadSeconds },
                                set: { seekPlayer(to: $0) }
                            ),
                            endSeconds: Binding(
                                get: { model.clipEndSeconds },
                                set: {
                                    model.setClipEnd($0)
                                }
                            ),
                            totalDurationSeconds: totalDurationSeconds,
                            visibleStartSeconds: visibleStartSeconds,
                            visibleEndSeconds: visibleEndSeconds,
                            captureMarkers: model.captureTimelineMarkers,
                            highlightedMarkerID: model.highlightedCaptureTimelineMarkerID,
                            onSeek: { seekPlayer(to: $0) }
                        )
                        .frame(height: 44)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { timelineInteractiveWidth = geo.size.width }
                                    .onChange(of: geo.size.width) { width in
                                        timelineInteractiveWidth = width
                                    }
                            }
                        )

                        if !isCompactLayout {
                            HStack {
                                Text("In: \(formatSeconds(model.clipStartSeconds))")
                                    .font(.caption.monospacedDigit())
                                Spacer()
                                Text("Playhead: \(formatSeconds(playheadSeconds))")
                                    .font(.caption.monospacedDigit())
                                Spacer()
                                Text("Out: \(formatSeconds(model.clipEndSeconds))")
                                    .font(.caption.monospacedDigit())
                            }
                            .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Text("Clip Start")
                                .frame(width: 70, alignment: .leading)
                            TextField("00:00:00.000", text: $model.clipStartText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onSubmit { model.commitClipStartText() }

                            Button("Set Start") {
                                model.setClipStart(playheadSeconds)
                            }
                            .buttonStyle(.bordered)
                        }
                        .font(.caption)

                        HStack(spacing: 8) {
                            Text("Clip End")
                                .frame(width: 70, alignment: .leading)
                            TextField("00:00:00.000", text: $model.clipEndText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onSubmit { model.commitClipEndText() }

                            Button("Set End") {
                                model.setClipEnd(playheadSeconds)
                            }
                            .buttonStyle(.bordered)
                        }
                        .font(.caption)

                        if !isCompactLayout {
                            HStack {
                                Text("Duration: \(formatSeconds(model.clipDurationSeconds))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                ControlGroup {
                                    Button {
                                        seekPlayer(to: model.clipStartSeconds)
                                    } label: {
                                        Image(systemName: "backward.end.fill")
                                    }
                                    .help("Jump to Clip Start")
                                    .accessibilityLabel("Jump to Clip Start")

                                    Button {
                                        seekPlayer(to: model.clipEndSeconds)
                                    } label: {
                                        Image(systemName: "forward.end.fill")
                                    }
                                    .help("Jump to Clip End")
                                    .accessibilityLabel("Jump to Clip End")
                                }
                                .controlSize(.mini)
                                .opacity(isTimelineHovered ? 0.95 : 0.0)
                                .allowsHitTesting(isTimelineHovered)
                                .animation(.easeOut(duration: 0.15), value: isTimelineHovered)

                                if model.hasVideoTrack {
                                    Button {
                                        model.captureFrame(at: playheadSeconds)
                                    } label: {
                                        Label("Capture Frame", systemImage: "camera")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .help("Save a PNG frame at the current playhead")
                                    .labelStyle(.titleAndIcon)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.leading, 2)
                                }
                            }
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
                    .onHover { hovering in
                        isTimelineHovered = hovering
                    }
                }

                GroupBox("Output") {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("", selection: $model.clipEncodingMode) {
                                if model.hasVideoTrack {
                                    Label("Fast", systemImage: "bolt.fill").tag(ClipEncodingMode.fast)
                                    Label("Advanced", systemImage: "slider.horizontal.3").tag(ClipEncodingMode.compressed)
                                }
                                Label("Audio Only", systemImage: "waveform").tag(ClipEncodingMode.audioOnly)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .controlSize(.regular)
                            .frame(maxWidth: .infinity)

                            Text(
                                model.clipEncodingMode == .fast
                                ? "Fast mode uses passthrough copy with minimal processing."
                                : model.clipEncodingMode == .compressed
                                    ? "Advanced mode unlocks codec, container, resolution, and bitrate options."
                                    : "Audio Only exports only audio from the selected clip range."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            Divider()

                            if model.clipEncodingMode == .audioOnly {
                                LabeledContent("Audio format") {
                                    Picker("Audio format", selection: $model.clipAudioOnlyFormat) {
                                        ForEach(ClipAudioOnlyFormat.allCases) { format in
                                            Text(format.rawValue).tag(format)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .frame(width: 148)
                                }

                                HStack {
                                    Text("Audio bitrate")
                                        .frame(width: 120, alignment: .leading)
                                    Slider(
                                        value: Binding(
                                            get: { Double(model.clipAudioBitrateKbps) },
                                            set: { model.clipAudioBitrateKbps = Int($0.rounded()) }
                                        ),
                                        in: 64...320,
                                        step: 32
                                    )
                                    .controlSize(.small)
                                    Text("\(model.clipAudioBitrateKbps) kbps")
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 90, alignment: .trailing)
                                }

                                Toggle("Boost audio (+10 dB, limit -0.1 dBFS)", isOn: $model.clipAudioOnlyBoostAudio)
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                Toggle("Add audio fade in/out (0.33s at start/end)", isOn: $model.clipAudioOnlyAddFadeInOut)
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                            } else {
                                LabeledContent("Format") {
                                    Picker("Format", selection: $model.selectedClipFormat) {
                                        if model.clipEncodingMode == .fast {
                                            ForEach(fastClipFormats) { format in
                                                Text(format.rawValue).tag(format)
                                            }
                                        } else {
                                            ForEach(advancedClipFormats) { format in
                                                Text(format.rawValue).tag(format)
                                            }
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .frame(width: 148)
                                }
                            }

                            if model.clipEncodingMode == .compressed {
                                if model.selectedClipFormat != .webm {
                                    LabeledContent("Video codec") {
                                        Picker("Video codec", selection: $model.clipAdvancedVideoCodec) {
                                            ForEach(AdvancedVideoCodec.allCases) { codec in
                                                Text(codec.rawValue).tag(codec)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .labelsHidden()
                                        .controlSize(.small)
                                        .frame(width: 148)
                                    }
                                } else {
                                    Text("Video codec: VP9 (WebM)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                LabeledContent("Speed") {
                                    Picker("Speed", selection: $model.clipCompatibleSpeedPreset) {
                                        ForEach(CompatibleSpeedPreset.allCases) { preset in
                                            Text(preset.rawValue).tag(preset)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .frame(width: 148)
                                }

                                LabeledContent("Max resolution") {
                                    Picker("Max resolution", selection: $model.clipCompatibleMaxResolution) {
                                        ForEach(CompatibleMaxResolution.allCases) { resolution in
                                            Text(resolution.rawValue).tag(resolution)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .frame(width: 148)
                                }

                                HStack {
                                    Text("Video bitrate")
                                        .frame(width: 120, alignment: .leading)
                                    Slider(value: $model.clipVideoBitrateMbps, in: 2...20, step: 0.5)
                                        .controlSize(.small)
                                    Text(String(format: "%.1f Mbps", model.clipVideoBitrateMbps))
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 90, alignment: .trailing)
                                }

                                HStack {
                                    Text("Audio bitrate")
                                        .frame(width: 120, alignment: .leading)
                                    Slider(
                                        value: Binding(
                                            get: { Double(model.clipAudioBitrateKbps) },
                                            set: { model.clipAudioBitrateKbps = Int($0.rounded()) }
                                        ),
                                        in: 64...320,
                                        step: 32
                                    )
                                    .controlSize(.small)
                                    Text("\(model.clipAudioBitrateKbps) kbps")
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 90, alignment: .trailing)
                                }

                                Toggle("Boost audio (+10 dB, limit -0.1 dBFS)", isOn: $model.clipAdvancedBoostAudio)
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                Toggle("Add audio fade in/out (0.33s at start/end)", isOn: $model.clipAdvancedAddFadeInOut)
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                Toggle("Auto-generate and burn captions (Whisper)", isOn: $model.clipAdvancedBurnInCaptions)
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                    .disabled(!model.whisperTranscriptionAvailable)

                                if !model.whisperTranscriptionAvailable {
                                    Text("Whisper binary/model not available in app bundle.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .tint(.secondary)
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                .stroke(Color.primary.opacity(0.05), lineWidth: 0.45)
                        )

                        Divider()

                        HStack {
                            if model.clipEncodingMode == .audioOnly, model.clipAudioOnlyFormat != .wav {
                                HStack(spacing: 8) {
                                    Label("Estimated output size", systemImage: "ruler")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.tertiary)
                                    Text(formatFileSize(model.estimatedClipAudioOnlySizeBytes))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            } else if model.clipEncodingMode == .compressed {
                                HStack(spacing: 8) {
                                    Label("Estimated output size", systemImage: "ruler")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.tertiary)
                                    Text(formatFileSize(model.estimatedClipAdvancedSizeBytes))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            Button {
                                model.commitClipStartText()
                                model.commitClipEndText()
                                model.startClipExport()
                            } label: {
                                Label(model.isExporting ? "Exporting…" : "Export Clip", systemImage: "film.stack")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canExportClip)
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
            } else {
                EmptyToolView(title: "Clip", subtitle: "Choose source media to create a new clip from a selected range.")
            }

            Spacer()
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissTimecodeFieldFocus()
                }
        }
        .onAppear {
            loadPlayerItem()
            installKeyMonitor()
            installScrollMonitor()
            installMouseDownMonitor()
        }
        .onChange(of: model.sourceURL?.path) { _ in
            loadPlayerItem()
        }
        .onChange(of: model.clipEncodingMode) { mode in
            if !model.hasVideoTrack && mode != .audioOnly {
                model.clipEncodingMode = .audioOnly
                return
            }
            if mode == .fast && !model.selectedClipFormat.supportsPassthrough {
                model.selectedClipFormat = .mp4
            }
        }
        .onChange(of: model.selectedClipFormat) { format in
            if format == .webm {
                model.clipAdvancedVideoCodec = .h264
            }
        }
        .onChange(of: timelineZoom) { _ in
            updateViewportForPlayhead(shouldFollow: false)
        }
        .onReceive(timer) { _ in
            let current = CMTimeGetSeconds(player.currentTime())
            if current.isFinite {
                playheadSeconds = max(0, current)
                if player.rate != 0 {
                    isViewportManuallyControlled = false
                }
                updateViewportForPlayhead(shouldFollow: player.rate != 0)
            }
            let currentDuration = CMTimeGetSeconds(player.currentItem?.duration ?? .invalid)
            if currentDuration.isFinite && currentDuration > 0 {
                playerDurationSeconds = currentDuration
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipSetStartAtPlayhead)) { _ in
            model.setClipStart(playheadSeconds)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipSetEndAtPlayhead)) { _ in
            model.setClipEnd(playheadSeconds)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipClearRange)) { _ in
            model.resetClipRange()
            seekPlayer(to: model.clipStartSeconds)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipJumpToStart)) { _ in
            seekPlayerAndFocusViewport(to: model.clipStartSeconds)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipJumpToEnd)) { _ in
            seekPlayerAndFocusViewport(to: model.clipEndSeconds)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipCaptureFrame)) { _ in
            model.captureFrame(at: playheadSeconds)
        }
        .onDisappear {
            waveformTask?.cancel()
            removeKeyMonitor()
            player.pause()
        }
    }
}

struct WaveformView: View {
    let samples: [Double]
    let startSeconds: Double
    let playheadSeconds: Double
    let endSeconds: Double
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let captureMarkers: [CaptureTimelineMarker]
    let highlightedMarkerID: UUID?
    let onSeek: (Double) -> Void
    @State private var dragWindowStart: Double?
    @State private var dragWindowEnd: Double?
    @State private var isHovered = false

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
            let height = proxy.size.height
            let startX = xPosition(for: startSeconds, width: width)
            let endX = xPosition(for: endSeconds, width: width)
            let playheadX = xPosition(for: playheadSeconds, width: width)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    .fill(Color.black.opacity(isHovered ? 0.16 : 0.12))

                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.42),
                                Color.accentColor.opacity(0.48),
                                Color.blue.opacity(0.44)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(1, endX - startX))
                    .offset(x: startX)
                    .overlay(
                        RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                            .stroke(Color.white.opacity(0.26), lineWidth: 0.7)
                            .frame(width: max(1, endX - startX))
                            .offset(x: startX)
                    )

                Canvas { context, size in
                    guard !samples.isEmpty else { return }
                    let n = max(samples.count - 1, 1)
                    let startIndex = max(0, Int((visibleStartSeconds / totalDurationSeconds) * Double(n)))
                    let endIndex = min(n, max(startIndex + 1, Int((visibleEndSeconds / totalDurationSeconds) * Double(n))))
                    let midY = size.height / 2.0
                    let halfHeight = max(1.0, (size.height - 8.0) / 2.0)

                    var path = Path()
                    let visibleSampleCount = max(1, endIndex - startIndex + 1)
                    let barPitch: CGFloat = 4.0
                    let barWidth: CGFloat = 2.6
                    let columnCount = max(1, Int((size.width / barPitch).rounded(.up)))
                    let visibleSampleCountDouble = Double(visibleSampleCount)

                    for column in 0..<columnCount {
                        let columnStartRatio = Double(column) / Double(columnCount)
                        let columnEndRatio = Double(column + 1) / Double(columnCount)
                        var columnStart = startIndex + Int((columnStartRatio * visibleSampleCountDouble).rounded(.down))
                        var columnEnd = startIndex + Int((columnEndRatio * visibleSampleCountDouble).rounded(.down)) - 1
                        columnStart = min(max(columnStart, startIndex), endIndex)
                        columnEnd = min(max(columnEnd, columnStart), endIndex)

                        var peak = 0.0
                        var i = columnStart
                        while i <= columnEnd {
                            peak = max(peak, samples[i])
                            i += 1
                        }

                        let normalized = max(0.02, min(1.0, peak))
                        let amp = CGFloat(normalized) * halfHeight
                        let centerX = ((CGFloat(column) + 0.5) / CGFloat(columnCount)) * size.width
                        let rect = CGRect(
                            x: centerX - (barWidth / 2.0),
                            y: midY - amp,
                            width: barWidth,
                            height: amp * 2.0
                        )
                        path.addRect(rect)
                    }

                    context.fill(path, with: .color(Color.primary.opacity(0.55)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: height)
                    .offset(x: playheadX - 1)

                ForEach(captureMarkers) { marker in
                    let markerX = xPosition(for: marker.seconds, width: width)
                    let isHighlighted = marker.id == highlightedMarkerID
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(isHighlighted ? Color.orange : Color.orange.opacity(0.72))
                        .frame(width: isHighlighted ? 5 : 3, height: isHighlighted ? height - 8 : height - 16)
                        .scaleEffect(isHighlighted ? 1.16 : 1.0, anchor: .center)
                        .shadow(
                            color: isHighlighted ? Color.orange.opacity(0.55) : Color.clear,
                            radius: isHighlighted ? 4 : 0
                        )
                        .offset(x: markerX - (isHighlighted ? 2.5 : 1.5), y: isHighlighted ? 4 : 8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                    .stroke(isHovered ? Color.accentColor.opacity(0.28) : Color.gray.opacity(0.16), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: highlightedMarkerID)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragWindowStart == nil || dragWindowEnd == nil {
                            dragWindowStart = visibleStartSeconds
                            dragWindowEnd = visibleEndSeconds
                        }
                        let windowStart = dragWindowStart ?? visibleStartSeconds
                        let windowEnd = dragWindowEnd ?? visibleEndSeconds
                        onSeek(timeValue(for: value.location.x, width: width, windowStart: windowStart, windowEnd: windowEnd))
                    }
                    .onEnded { _ in
                        dragWindowStart = nil
                        dragWindowEnd = nil
                    }
            )
            .overlay(alignment: .bottomLeading) {
                Text(formatSeconds(visibleStartSeconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .padding(.bottom, 4)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(formatSeconds(visibleEndSeconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
            }
        }
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

            ZStack(alignment: .leading) {
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
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .offset(x: startX - 7, y: 13)
                    .overlay(
                        Circle()
                            .stroke(Color.accentColor.opacity(0.95), lineWidth: 2)
                            .frame(width: 14, height: 14)
                            .offset(x: startX - 7, y: 13)
                    )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let newValue = min(timeValue(for: value.location.x, width: width, windowStart: visibleStartSeconds, windowEnd: visibleEndSeconds), endSeconds)
                                startSeconds = max(0, newValue)
                            }
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .offset(x: endX - 7, y: 13)
                    .overlay(
                        Circle()
                            .stroke(Color.accentColor.opacity(0.95), lineWidth: 2)
                            .frame(width: 14, height: 14)
                            .offset(x: endX - 7, y: 13)
                    )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let newValue = max(timeValue(for: value.location.x, width: width, windowStart: visibleStartSeconds, windowEnd: visibleEndSeconds), startSeconds)
                                endSeconds = min(totalDurationSeconds, newValue)
                            }
                    )
            }
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
            )
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
        guard maxOffset > 0 else {
            onViewportStartChanged(0)
            return
        }

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
    let isCompactLayout: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
    @ObservedObject var model: WorkspaceViewModel
    @StateObject private var externalOpenBridge = ExternalFileOpenBridge.shared
    @State private var isDropTargeted = false
    @State private var appWindow: NSWindow?

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
                model.setSource(url)
                NSApp.activate(ignoringOtherApps: true)
                externalOpenBridge.incomingURL = nil
            }
        }
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

struct PreferencesView: View {
    @ObservedObject var model: WorkspaceViewModel
    @State private var profanityEntry = ""

    var body: some View {
        TabView {
            Form {
                Section {
                    Picker("Theme", selection: $model.appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.radioGroup)
                } header: {
                    Text("Appearance")
                }

                Section {
                    LabeledContent("Completion Sound") {
                        Picker("Completion Sound", selection: $model.completionSound) {
                            ForEach(CompletionSound.allCases) { sound in
                                Text(sound.displayName).tag(sound)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    HStack {
                        Spacer()
                        Button("Play Preview") {
                            guard let soundName = model.completionSound.soundName,
                                  let sound = NSSound(named: soundName) else { return }
                            sound.play()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.completionSound == .none)
                    }
                } header: {
                    Text("Notifications")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            Form {
                Section {
                    LabeledContent("Silence Gap Threshold") {
                        Stepper(value: $model.silenceMinDurationSeconds, in: 0.5...5.0, step: 0.5) {
                            Text("\(model.silenceMinDurationLabel)s")
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 160, alignment: .trailing)
                    }
                } header: {
                    Text("Detection")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Words (\(model.selectedProfanityWordsCount))")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)],
                            alignment: .leading,
                            spacing: 6
                        ) {
                            ForEach(model.selectedProfanityWordsList, id: \.self) { word in
                                HStack(spacing: 6) {
                                    Text(word)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Button {
                                        model.removeProfanityWord(word)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .help("Remove \(word)")
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.thinMaterial, in: Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous))

                        HStack {
                            TextField("Add word(s)…", text: $profanityEntry)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    model.addProfanityWords(from: profanityEntry)
                                    profanityEntry = ""
                                }
                            Button("Add") {
                                model.addProfanityWords(from: profanityEntry)
                                profanityEntry = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button("Reset to Defaults") {
                                model.resetProfanityWordsToDefaults()
                                profanityEntry = ""
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text("Add one word or paste multiple words separated by commas/spaces/new lines.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Profanity Words")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Analyze", systemImage: "waveform.path.ecg")
            }

            Form {
                Section {
                    LabeledContent("Default Encoding") {
                        Picker("Default Encoding", selection: $model.defaultClipEncodingMode) {
                            ForEach(ClipEncodingMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    LabeledContent("Jump Interval") {
                        Stepper(value: $model.jumpIntervalSeconds, in: 1...30, step: 1) {
                            Text("\(model.jumpIntervalSeconds)s")
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 160, alignment: .trailing)
                    }
                } header: {
                    Text("Timeline")
                }

                Section {
                    LabeledContent("Save Location") {
                        Picker("Save Location", selection: $model.frameSaveLocationMode) {
                            ForEach(FrameSaveLocationMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }

                    if model.frameSaveLocationMode == .customFolder {
                        LabeledContent("Custom Folder") {
                            HStack(spacing: 8) {
                                Text(model.customFrameSaveDirectoryPath.isEmpty ? "Not set" : model.customFrameSaveDirectoryPath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(model.customFrameSaveDirectoryPath.isEmpty ? .secondary : .primary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Button("Choose…") {
                                    model.chooseCustomFrameSaveDirectory()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .frame(width: 340)
                        }
                    }
                } header: {
                    Text("Frame Capture")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Preset") {
                            Picker("Preset", selection: $model.advancedClipFilenamePreset) {
                                ForEach(AdvancedFilenamePreset.allCases) { preset in
                                    Text(preset.rawValue).tag(preset)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 260)
                        }

                        HStack(spacing: 8) {
                            Text("Preview:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(model.advancedClipFilenamePreview)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Reset to Defaults") {
                                model.resetAdvancedClipFilenameTemplateToDefaults()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text("Preset-based naming keeps exports consistent for non-technical users.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("Advanced Export Filename")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Clip", systemImage: "timeline.selection")
            }

            Form {
                Section {
                    LabeledContent("Default MP3 Bitrate") {
                        Stepper(value: $model.defaultAudioBitrateKbps, in: 64...320, step: 32) {
                            Text("\(model.defaultAudioBitrateKbps) kbps")
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 180, alignment: .trailing)
                    }
                } header: {
                    Text("Export")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Audio", systemImage: "waveform")
            }
        }
        .padding(14)
        .frame(width: 620, height: 460)
    }
}

struct HelpDocumentationView: View {
    private struct HelpSection: Identifiable {
        let id = UUID()
        let title: String
        let items: [String]
    }

    private let sections: [HelpSection] = [
        HelpSection(
            title: "Getting Started",
            items: [
                "Choose a media file with Choose Media, or drag a file into the main window.",
                "Use the top tool tabs to switch between Clip, Analyze, Convert, and Inspect.",
                "The footer always shows current activity, progress, and completion state."
            ]
        ),
        HelpSection(
            title: "Clip Tab",
            items: [
                "Create new clips by setting In/Out points on the timeline.",
                "Set points with drag handles, direct timecode entry, keyboard shortcuts, or playhead actions.",
                "Choose Fast, Advanced, or Audio Only export modes depending on speed and compatibility needs."
            ]
        ),
        HelpSection(
            title: "Analyze Tab",
            items: [
                "Run black-frame detection, silence-gap detection, and profanity detection.",
                "Watch results populate while processing, including timeline markers and segment lists.",
                "Double-click detected rows to jump playback to those timestamps."
            ]
        ),
        HelpSection(
            title: "Convert Tab",
            items: [
                "Export full-file audio using MP3 or M4A formats.",
                "Set bitrate and export destination from one panel.",
                "Use this tab for audio extraction without creating a timeline clip."
            ]
        ),
        HelpSection(
            title: "Inspect Tab",
            items: [
                "Review source metadata such as duration, bitrate, codec, frame rate, and resolution.",
                "Use Show in Finder to jump to the current source file.",
                "Use this tab as a quick technical snapshot before export or analysis."
            ]
        ),
        HelpSection(
            title: "Keyboard Shortcuts",
            items: [
                "I: Set clip start at playhead",
                "O: Set clip end at playhead",
                "X: Clear clip in/out",
                "Up Arrow: Jump to clip start",
                "Down Arrow: Jump to clip end",
                "Cmd-E: Export clip",
                "Cmd-Shift-E: Quick export clip (no save dialog)",
                "Cmd-Option-E: Export audio",
                "Cmd-R: Run analysis",
                "Cmd-.: Stop active analysis/export"
            ]
        ),
        HelpSection(
            title: "Bundled Components",
            items: [
                "ffmpeg is bundled for conversion/export workflows.",
                "whisper-cli + bundled model are used for profanity detection and caption generation.",
                "If Whisper resources are missing, rebuild with bundled resources."
            ]
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Bulwark Video Tools Help")
                    .font(.title2.weight(.semibold))

                Text("Quick guide to core workflows and shortcuts.")
                    .foregroundStyle(.secondary)

                ForEach(sections) { section in
                    GroupBox(section.title) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(section.items, id: \.self) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•")
                                    Text(item)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private func firstExistingFileURL(from paths: [String]) -> URL? {
        for path in paths {
            guard !path.isEmpty else { continue }
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let url = firstExistingFileURL(from: filenames) {
            DispatchQueue.main.async {
                ExternalFileOpenBridge.shared.open(url)
            }
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard let url = firstExistingFileURL(from: [filename]) else { return false }
        DispatchQueue.main.async {
            ExternalFileOpenBridge.shared.open(url)
        }
        return true
    }
}

@main
struct CheckBlackFramesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = WorkspaceViewModel()

    var body: some Scene {
        Window("Bulwark Video Tools", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .windowResizability(.contentMinSize)

        Window("Bulwark Video Tools Help", id: "help") {
            HelpDocumentationView()
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .defaultSize(width: 760, height: 680)
        .windowResizability(.contentSize)

        .commands {
            CommandGroup(after: .textEditing) {
                Divider()

                Button("Set Clip Start at Playhead") {
                    NotificationCenter.default.post(name: .clipSetStartAtPlayhead, object: nil)
                }
                .keyboardShortcut("i", modifiers: [])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil)

                Button("Set Clip End at Playhead") {
                    NotificationCenter.default.post(name: .clipSetEndAtPlayhead, object: nil)
                }
                .keyboardShortcut("o", modifiers: [])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil)

                Button("Clear Clip In/Out") {
                    NotificationCenter.default.post(name: .clipClearRange, object: nil)
                }
                .keyboardShortcut("x", modifiers: [])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil)

                Button("Export Clip") {
                    model.startClipExport()
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(model.selectedTool != .clip || !model.canExportClip)

                Button("Quick Export Clip") {
                    model.startClipExport(skipSaveDialog: true)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selectedTool != .clip || !model.canExportClip)

                Button("Jump to Clip Start") {
                    NotificationCenter.default.post(name: .clipJumpToStart, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil)

                Button("Jump to Clip End") {
                    NotificationCenter.default.post(name: .clipJumpToEnd, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil)
            }

            CommandGroup(replacing: .newItem) {
                Button("Choose Media…") {
                    model.chooseSource()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Close Media") {
                    model.clearSource()
                }
                .disabled(model.sourceURL == nil || model.isAnalyzing || model.isExporting)
            }

            CommandMenu("Tool") {
                Button("Clip") { model.selectedTool = .clip }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Analyze") { model.selectedTool = .analyze }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Convert") { model.selectedTool = .convert }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("Inspect") { model.selectedTool = .inspect }
                    .keyboardShortcut("4", modifiers: [.command])
            }

            CommandMenu("Analyze") {
                Button("Run Analysis") {
                    model.startAnalysis()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!model.canAnalyze)

                Button("Stop Analysis") {
                    model.stopAnalysis()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!model.isAnalyzing)
            }

            CommandMenu("Export") {
                Button("Export Audio…") {
                    model.startExport()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!model.canExport)

                Button("Export Clip…") {
                    model.startClipExport()
                }
                .disabled(!model.canExportClip)

                Button("Quick Export Clip") {
                    model.startClipExport(skipSaveDialog: true)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.canExportClip)

                Divider()

                Button("Capture Frame…") {
                    NotificationCenter.default.post(name: .clipCaptureFrame, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil || !model.hasVideoTrack || model.isAnalyzing || model.isExporting)
            }

            CommandGroup(replacing: .help) {
                Button("Bulwark Video Tools Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            }
        }

        Settings {
            PreferencesView(model: model)
        }
    }
}
