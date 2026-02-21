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
}

private let minDurationSeconds = 0.001
private let picThreshold = 0.90
private let pixelBlackThreshold = 0.10
private let maxSampleDimension = 640

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

struct Segment: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    let duration: Double

    var formatted: String {
        "\(formatSeconds(start)) → \(formatSeconds(end)) (\(String(format: "%.3f", duration))s)"
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
    let mediaDuration: Double?
}

struct FileAnalysis {
    let fileURL: URL
    var segments: [Segment] = []
    var mediaDuration: Double?
    var progress: Double = 0
    var status: FileStatus = .idle

    var totalDuration: Double {
        segments.reduce(0.0) { $0 + $1.duration }
    }

    var summary: String {
        switch status {
        case .idle:
            return "Ready"
        case .running:
            return "Analyzing… \(Int((progress * 100).rounded()))%"
        case .done:
            if segments.isEmpty {
                return "No black segments"
            }
            return "\(segments.count) segment(s), total \(String(format: "%.3f", totalDuration))s"
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }

    var formattedList: String {
        segments.map(\.formatted).joined(separator: "\n")
    }

    var timelineDuration: Double? {
        if let mediaDuration, mediaDuration > 0 {
            return mediaDuration
        }
        let maxEnd = segments.map(\.end).max() ?? 0
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
    progressHandler: @escaping @Sendable (Double) -> Void = { _ in },
    shouldCancel: @escaping @Sendable () -> Bool = { false }
) -> Result<DetectionOutput, DetectionError> {
    let asset = AVAsset(url: file)
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

    var intervals: [(start: Double, end: Double)] = []
    var inBlack = false
    var currentStart = 0.0
    var lastTimestamp = 0.0

    var estimatedFrameDuration = CMTimeGetSeconds(track.minFrameDuration)
    if !estimatedFrameDuration.isFinite || estimatedFrameDuration <= 0 {
        estimatedFrameDuration = 1.0 / max(track.nominalFrameRate > 0 ? Double(track.nominalFrameRate) : 30.0, 1.0)
    }

    let mediaDuration = CMTimeGetSeconds(asset.duration)
    let safeDuration = mediaDuration.isFinite && mediaDuration > 0 ? mediaDuration : nil

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
            progressHandler(min(0.99, max(0, frameEnd / safeDuration)))
        }

        if isFrameMostlyBlack(sample) {
            if !inBlack {
                inBlack = true
                currentStart = pts
            }
        } else if inBlack {
            intervals.append((start: currentStart, end: pts))
            inBlack = false
        }
    }

    if inBlack {
        intervals.append((start: currentStart, end: lastTimestamp))
    }

    if reader.status == .failed {
        let reason = reader.error?.localizedDescription ?? "Unknown reader failure"
        return .failure(.failed("Reader failed: \(reason)"))
    }

    progressHandler(1.0)
    let outputDuration = mediaDuration.isFinite && mediaDuration > 0 ? mediaDuration : (lastTimestamp > 0 ? lastTimestamp : nil)
    let segments = buildSegments(blackIntervals: intervals, minDuration: minDurationSeconds)
    return .success(DetectionOutput(segments: segments, mediaDuration: outputDuration))
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
final class WorkspaceViewModel: ObservableObject {
    private enum DefaultsKey {
        static let audioBitrateKbps = "prefs.audioBitrateKbps"
        static let defaultClipEncodingMode = "prefs.defaultClipEncodingMode"
        static let jumpIntervalSeconds = "prefs.jumpIntervalSeconds"
        static let completionSound = "prefs.completionSound"
        static let appearance = "prefs.appearance"
    }

    @Published var selectedTool: WorkspaceTool = .clip
    @Published var sourceURL: URL?
    @Published var analysis: FileAnalysis?
    @Published var sourceInfo: SourceMediaInfo?

    @Published var isAnalyzing = false
    @Published var analyzeProgress = 0.0
    @Published var analyzeStatusText = ""
    @Published var wasCancelled = false

    @Published var selectedAudioFormat: AudioFormat = .mp3
    @Published var audioBitrateKbps = 128 {
        didSet {
            UserDefaults.standard.set(audioBitrateKbps, forKey: DefaultsKey.audioBitrateKbps)
        }
    }
    @Published var isExporting = false
    @Published var exportProgress = 0.0
    @Published var exportStatusText = "No export yet"
    @Published var outputURL: URL?

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
    @Published var clipAudioOnlyBoostAudio = false
    @Published var clipAudioOnlyAddFadeInOut = false
    @Published var clipAudioOnlyFormat: ClipAudioOnlyFormat = .mp3
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
    @Published var appearance: AppAppearance = .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: DefaultsKey.appearance)
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

    private func loadPreferences() {
        let defaults = UserDefaults.standard

        let savedBitrate = defaults.integer(forKey: DefaultsKey.audioBitrateKbps)
        if savedBitrate > 0 {
            audioBitrateKbps = min(max(64, savedBitrate), 320)
        }

        if let rawMode = defaults.string(forKey: DefaultsKey.defaultClipEncodingMode),
           let mode = ClipEncodingMode(rawValue: rawMode) {
            defaultClipEncodingMode = mode
        }
        clipEncodingMode = defaultClipEncodingMode

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
    }

    var canAnalyze: Bool {
        sourceURL != nil && !isAnalyzing && !isExporting
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
        panel.message = "Choose a video file"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.urls.first {
            setSource(url)
        }
    }

    func setSource(_ url: URL) {
        guard !isAnalyzing && !isExporting else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        sourceURL = url
        analysis = FileAnalysis(fileURL: url)
        sourceInfo = loadSourceMediaInfo(for: url)
        clipEncodingMode = defaultClipEncodingMode
        applySuggestedClipBitrateFromSource()
        outputURL = nil
        uiMessage = "Loaded \(url.lastPathComponent)"
        wasCancelled = false
        analyzeProgress = 0
        exportProgress = 0
        resetClipRange()
    }

    func clearSource() {
        guard !isAnalyzing && !isExporting else { return }
        sourceURL = nil
        analysis = nil
        sourceInfo = nil
        outputURL = nil
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

        isAnalyzing = true
        lastActivityState = .running
        wasCancelled = false
        analyzeProgress = 0
        analyzeStatusText = "Analyzing \(url.lastPathComponent)… 0%"
        cancelFlag.reset()

        if var existing = analysis {
            existing.status = .running
            existing.progress = 0
            existing.segments = []
            existing.mediaDuration = nil
            analysis = existing
        } else {
            analysis = FileAnalysis(fileURL: url, status: .running)
        }

        analyzeTask = Task { [weak self] in
            guard let self else { return }
            let flag = cancelFlag
            let result = await Task.detached(priority: .userInitiated) {
                runDetection(file: url) { progress in
                    Task { @MainActor [weak self] in
                        self?.setAnalyzeProgress(progress, fileName: url.lastPathComponent)
                    }
                } shouldCancel: {
                    flag.isCancelled()
                }
            }.value

            self.applyAnalysisResult(result)
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
        analyzeStatusText = "Analyzing \(fileName)… \(Int((clamped * 100).rounded()))%"
        if var current = analysis {
            current.progress = clamped
            analysis = current
        }
    }

    private func applyAnalysisResult(_ result: Result<DetectionOutput, DetectionError>) {
        isAnalyzing = false
        analyzeTask = nil
        analyzeProgress = 0

        guard var current = analysis else { return }
        switch result {
        case .success(let output):
            current.segments = output.segments
            current.mediaDuration = output.mediaDuration
            current.progress = 1
            current.status = .done
            analysis = current
            uiMessage = current.segments.isEmpty ? "No black segments found." : "Detected \(current.segments.count) black segment(s)."
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
                        "-b:a", "\(max(64, self.audioBitrateKbps))k",
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

    func startClipExport() {
        guard canExportClip, let sourceURL else { return }

        clampClipRange()
        guard clipDurationSeconds > 0 else { return }

        let outputExtension = clipEncodingMode == .audioOnly ? clipAudioOnlyFormat.fileExtension : selectedClipFormat.fileExtension
        let defaultName = sourceURL.deletingPathExtension().lastPathComponent +
            "_clip_" + formatSeconds(clipStartSeconds).replacingOccurrences(of: ":", with: "-") +
            "_to_" + formatSeconds(clipEndSeconds).replacingOccurrences(of: ":", with: "-") +
            "." + outputExtension

        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [clipEncodingMode == .audioOnly ? clipAudioOnlyFormat.contentType : selectedClipFormat.contentType]
        panel.canCreateDirectories = true
        panel.title = "Export Clip"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        try? FileManager.default.removeItem(at: destination)

        isExporting = true
        lastActivityState = .running
        exportCancellationRequested = false
        exportProgress = 0
        exportStatusText = "Exporting clip…"
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
            let start = String(format: "%.3f", self.clipStartSeconds)
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
            var ffmpegArgs = [
                "-y",
                "-hide_banner",
                "-loglevel", "error",
                "-ss", start,
                "-t", durationStr,
                "-i", sourceURL.path,
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

            let encodeError = await self.runFFmpegProcessWithProgress(
                executableURL: ffmpegURL,
                arguments: ffmpegArgs,
                durationSeconds: clipDuration,
                statusPrefix: "Encoding advanced clip"
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

    private func runFFmpegProcessWithProgress(
        executableURL: URL,
        arguments: [String],
        durationSeconds: Double,
        statusPrefix: String
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
                    self.exportProgress = clamped
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

    private func fileIcon(for url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(model.sourceURL == nil ? "Choose Video" : "Change Video") {
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
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.6)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
    }
}

struct ToolContentView: View {
    @ObservedObject var model: WorkspaceViewModel
    let isCompactLayout: Bool

    var body: some View {
        TabView(selection: $model.selectedTool) {
            ScrollView {
                ClipToolView(model: model, isCompactLayout: isCompactLayout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .tabItem { Text(WorkspaceTool.clip.rawValue) }
            .tag(WorkspaceTool.clip)

            ScrollView {
                AnalyzeToolView(model: model, isCompactLayout: isCompactLayout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .tabItem { Text(WorkspaceTool.analyze.rawValue) }
            .tag(WorkspaceTool.analyze)

            ScrollView {
                ConvertToolView(model: model, isCompactLayout: isCompactLayout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
            }
            .scrollIndicators(.automatic)
            .tabItem { Text(WorkspaceTool.inspect.rawValue) }
            .tag(WorkspaceTool.inspect)
        }
    }
}

struct AnalyzeToolView: View {
    @ObservedObject var model: WorkspaceViewModel
    let isCompactLayout: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    model.startAnalysis()
                } label: {
                    Label(model.isAnalyzing ? "Analyzing…" : "Run Black Frame Analysis", systemImage: "waveform.path.ecg")
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

            if let analysis = model.analysis {
                Text(analysis.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let analysis = model.analysis {
                DetailView(file: analysis, isCompactLayout: isCompactLayout, model: model)
            } else {
                EmptyToolView(title: "Analyze", subtitle: "Choose a video and run black-frame analysis.")
            }
        }
    }
}

struct ConvertToolView: View {
    @ObservedObject var model: WorkspaceViewModel
    let isCompactLayout: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                                get: { Double(model.audioBitrateKbps) },
                                set: { model.audioBitrateKbps = Int($0.rounded()) }
                            ), in: 96...320, step: 32)
                            .controlSize(.small)
                            Text("\(model.audioBitrateKbps) kbps")
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
                        Spacer()
                        Button {
                            model.startExport()
                        } label: {
                            Label(model.isExporting ? "Exporting…" : "Export Audio", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canExport)
                    }
                }
                .padding(6)
            }

            if let source = model.sourceURL {
                Text("Source: \(source.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                EmptyToolView(title: "Convert", subtitle: "Choose a source video to enable audio export.")
            }
        }
    }
}

struct ClipToolView: View {
    @ObservedObject var model: WorkspaceViewModel
    let isCompactLayout: Bool

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
        waveformSamples = []
        isWaveformLoading = true

        let targetSampleCount = Int(min(24_000, max(4_000, model.sourceDurationSeconds * 40.0)))

        waveformTask = Task.detached(priority: .userInitiated) {
            let samples = generateWaveformSamples(for: url, sampleCount: targetSampleCount)
            await MainActor.run {
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
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                    .padding(6)
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
                            }
                        }
                    }
                    .padding(6)
                    .onHover { hovering in
                        isTimelineHovered = hovering
                    }
                }

                GroupBox("Output") {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("", selection: $model.clipEncodingMode) {
                                Label("Fast", systemImage: "bolt.fill").tag(ClipEncodingMode.fast)
                                Label("Advanced", systemImage: "slider.horizontal.3").tag(ClipEncodingMode.compressed)
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
                                    .controlSize(.small)

                                Toggle("Add audio fade in/out (0.33s at start/end)", isOn: $model.clipAudioOnlyAddFadeInOut)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)

                                Text("Audio-only mode exports only the selected range's audio track.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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

                            if model.clipEncodingMode == .fast {
                                Text("Fast mode uses passthrough (original codecs/bitrate) and supports MP4/MOV.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if model.clipEncodingMode == .compressed {
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
                                    .controlSize(.small)

                                Toggle("Add audio fade in/out (0.33s at start/end)", isOn: $model.clipAdvancedAddFadeInOut)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)

                                Text("Advanced mode uses configurable codecs, bitrate, and container.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .tint(.secondary)
                        .padding(10)
                        .background(Color.gray.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Divider()

                        HStack {
                            Spacer()
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
                    .padding(6)
                }
            } else {
                EmptyToolView(title: "Clip", subtitle: "Choose a source video to create a new clip from a selected range.")
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.gray.opacity(isHovered ? 0.18 : 0.12))

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: max(1, endX - startX))
                    .offset(x: startX)

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
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isHovered ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.25), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.gray.opacity(isHovered ? 0.26 : 0.2))
                    .frame(height: 10)
                    .offset(y: 15)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(2, endX - startX), height: 10)
                    .offset(x: startX, y: 15)

                Rectangle()
                    .fill(Color.accentColor)
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
                    .fill(Color.accentColor)
                    .frame(width: 14, height: 14)
                    .offset(x: startX - 7, y: 13)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let newValue = min(timeValue(for: value.location.x, width: width, windowStart: visibleStartSeconds, windowEnd: visibleEndSeconds), endSeconds)
                                startSeconds = max(0, newValue)
                            }
                    )

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 14, height: 14)
                    .offset(x: endX - 7, y: 13)
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
                    .padding(6)
                }

                GroupBox("Analysis Snapshot") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Detected segments: \(analysis?.segments.count ?? 0)")
                        Text("Total black duration: \(String(format: "%.3f", analysis?.totalDuration ?? 0))s")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
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
                    .padding(6)
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
                    .padding(6)
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
                }
            } else {
                EmptyToolView(title: "Inspect", subtitle: "Choose a source video to inspect metadata and results.")
            }

            if !isCompactLayout {
                Spacer()
            }
        }
    }
}

struct StatusFooterStripView: View {
    @ObservedObject var model: WorkspaceViewModel

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
        if #available(macOS 14.0, *) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

struct SegmentTimelineView: View {
    let segments: [Segment]
    let duration: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.gray.opacity(0.18))
                        .frame(height: 18)

                    ForEach(segments) { segment in
                        let safeDuration = max(duration, 0.001)
                        let startRatio = max(0, min(1, segment.start / safeDuration))
                        let widthRatio = max(0, min(1 - startRatio, segment.duration / safeDuration))
                        let x = geometry.size.width * startRatio
                        let w = max(2, geometry.size.width * widthRatio)

                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.black.opacity(0.85))
                            .frame(width: w, height: 18)
                            .offset(x: x)
                    }
                }
            }
            .frame(height: 18)

            HStack {
                Text("00:00:00.000")
                Spacer()
                Text(formatSeconds(duration))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(file.fileURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            InlinePlayerView(player: player)
                .frame(
                    minHeight: isCompactLayout ? 150 : 260,
                    maxHeight: isCompactLayout ? 210 : 320
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if !isCompactLayout {
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
            }

            switch file.status {
            case .running:
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Analyzing \(file.fileURL.lastPathComponent)…")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            case .failed(let reason):
                Text("Analysis failed: \(reason)")
                    .foregroundStyle(.red)
            case .idle:
                Text("Ready to analyze")
                    .foregroundStyle(.secondary)
            case .done:
                if file.segments.isEmpty {
                    Label("No black segments detected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Text("Detected \(file.segments.count) segment(s)")
                            .font(.headline)
                        Spacer()
                        Button("Copy List") {
                            copyToClipboard(file.formattedList)
                        }
                    }
                }

                if let timelineDuration = file.timelineDuration {
                    SegmentTimelineView(segments: file.segments, duration: timelineDuration)
                }

                if !file.segments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Detected Segments")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

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
                                    .background(Color.gray.opacity(0.10))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        play(from: segment.start)
                                    }
                                    .help("Double-click to play from this segment start")
                                }
                            }
                        }
                        .frame(minHeight: 150)
                    }
                }
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

            VStack(alignment: .leading, spacing: isCompactLayout ? 8 : 10) {
                SourceHeaderView(model: model)

                ToolContentView(model: model, isCompactLayout: isCompactLayout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                StatusFooterStripView(model: model)
            }
            .padding(isCompactLayout ? 8 : 12)
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
                    Label(model.sourceURL == nil ? "Choose Video" : "Change Video", systemImage: "video.badge.plus")
                }
            }
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: WorkspaceViewModel

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
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Clip", systemImage: "timeline.selection")
            }

            Form {
                Section {
                    LabeledContent("Default MP3 Bitrate") {
                        Stepper(value: $model.audioBitrateKbps, in: 64...320, step: 32) {
                            Text("\(model.audioBitrateKbps) kbps")
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
        .frame(width: 540, height: 320)
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
    @StateObject private var model = WorkspaceViewModel()

    var body: some Scene {
        Window("Bulwark Video Tools", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .windowResizability(.contentMinSize)
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
                Button("Choose Video…") {
                    model.chooseSource()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Close Video") {
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
                Button("Run Black Frame Analysis") {
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
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.canExport)

                Button("Export Clip…") {
                    model.startClipExport()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!model.canExportClip)
            }
        }

        Settings {
            PreferencesView(model: model)
        }
    }
}
