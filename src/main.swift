import AppKit
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine

private let minDurationSeconds = 0.001
private let picThreshold = 0.90
private let pixelBlackThreshold = 0.10
private let maxSampleDimension = 640

enum WorkspaceTool: String, CaseIterable, Identifiable {
    case analyze = "Analyze"
    case convert = "Convert"
    case clip = "Clip"
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

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .mov: return "mov"
        }
    }

    var fileType: AVFileType {
        switch self {
        case .mp4: return .mp4
        case .mov: return .mov
        }
    }

    var contentType: UTType {
        switch self {
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        }
    }
}

enum ClipEncodingMode: String, CaseIterable, Identifiable {
    case fast = "Fast (Original)"
    case compressed = "More Compatible"

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
final class WorkspaceViewModel: ObservableObject {
    @Published var selectedTool: WorkspaceTool = .analyze
    @Published var sourceURL: URL?
    @Published var analysis: FileAnalysis?
    @Published var sourceInfo: SourceMediaInfo?

    @Published var isAnalyzing = false
    @Published var analyzeProgress = 0.0
    @Published var analyzeStatusText = ""
    @Published var wasCancelled = false

    @Published var selectedAudioFormat: AudioFormat = .mp3
    @Published var audioBitrateKbps = 128
    @Published var isExporting = false
    @Published var exportProgress = 0.0
    @Published var exportStatusText = "No export yet"
    @Published var outputURL: URL?

    @Published var clipStartSeconds: Double = 0
    @Published var clipEndSeconds: Double = 0
    @Published var clipStartText = "00:00:00.000"
    @Published var clipEndText = "00:00:00.000"
    @Published var selectedClipFormat: ClipFormat = .mp4
    @Published var clipEncodingMode: ClipEncodingMode = .fast
    @Published var clipVideoBitrateMbps: Double = 4.0

    @Published var uiMessage = "Ready"

    private var analyzeTask: Task<Void, Never>?
    private let cancelFlag = CancellationFlag()

    init() {
        if let firstArg = CommandLine.arguments.dropFirst().first {
            let url = URL(fileURLWithPath: firstArg)
            if FileManager.default.fileExists(atPath: url.path) {
                setSource(url)
            }
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

    func resetClipRange() {
        let duration = max(0, sourceInfo?.durationSeconds ?? analysis?.mediaDuration ?? 0)
        clipStartSeconds = 0
        clipEndSeconds = duration
        clipStartText = formatSeconds(clipStartSeconds)
        clipEndText = formatSeconds(clipEndSeconds)
    }

    private func applySuggestedClipBitrateFromSource() {
        guard let sourceVideoBps = sourceInfo?.videoBitrateBps, sourceVideoBps > 0 else { return }

        let step = 0.5
        let sliderMin = 2.0
        let sliderMax = 20.0
        let sourceMbps = sourceVideoBps / 1_000_000.0
        let nearestTick = (sourceMbps / step).rounded() * step
        let suggested = nearestTick + step
        clipVideoBitrateMbps = min(sliderMax, max(sliderMin, suggested))
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
            if let sound = NSSound(named: NSSound.Name("Crystal")) ?? NSSound(named: NSSound.Name("Glass")) {
                sound.play()
            }
        case .failure(.cancelled):
            current.status = .failed("Stopped")
            analysis = current
            wasCancelled = true
            analyzeStatusText = "Analysis stopped"
            uiMessage = "Analysis stopped"
        case .failure(.failed(let reason)):
            current.status = .failed(reason)
            analysis = current
            analyzeStatusText = "Analysis failed"
            uiMessage = "Analysis failed: \(reason)"
        }
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
        exportProgress = 0
        exportStatusText = "Preparing export…"
        outputURL = nil

        let asset = AVURLAsset(url: sourceURL)
        try? FileManager.default.removeItem(at: destination)

        Task { [weak self] in
            guard let self else { return }

            if self.selectedAudioFormat == .m4a {
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    await MainActor.run {
                        self.isExporting = false
                        self.exportStatusText = "Export failed: Unable to create export session"
                        self.uiMessage = self.exportStatusText
                    }
                    return
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
                    self.isExporting = false
                    self.exportProgress = 0

                    switch session.status {
                    case .completed:
                        self.outputURL = destination
                        self.exportStatusText = "Export complete: \(destination.lastPathComponent)"
                        self.uiMessage = self.exportStatusText
                    case .failed:
                        self.exportStatusText = "Export failed: \(session.error?.localizedDescription ?? "Unknown error")"
                        self.uiMessage = self.exportStatusText
                    case .cancelled:
                        self.exportStatusText = "Export cancelled"
                        self.uiMessage = self.exportStatusText
                    default:
                        self.exportStatusText = "Export ended with status: \(session.status.rawValue)"
                        self.uiMessage = self.exportStatusText
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
                mp3Error = await self.runProcess(
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
                    ]
                )
            } else {
                mp3Error = "No ffmpeg executable found. Bundle ffmpeg at Contents/Resources/ffmpeg or install it on this Mac."
            }

            await MainActor.run {
                self.isExporting = false
                self.exportProgress = 0
                if let mp3Error {
                    self.exportStatusText = "MP3 export failed: \(mp3Error)"
                    self.uiMessage = self.exportStatusText
                } else {
                    self.outputURL = destination
                    self.exportStatusText = "Export complete: \(destination.lastPathComponent)"
                    self.uiMessage = self.exportStatusText
                }
            }
        }
    }

    func startClipExport() {
        guard canExportClip, let sourceURL else { return }

        clampClipRange()
        guard clipDurationSeconds > 0 else { return }

        let defaultName = sourceURL.deletingPathExtension().lastPathComponent +
            "_clip_" + formatSeconds(clipStartSeconds).replacingOccurrences(of: ":", with: "-") +
            "_to_" + formatSeconds(clipEndSeconds).replacingOccurrences(of: ":", with: "-") +
            "." + selectedClipFormat.fileExtension

        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [selectedClipFormat.contentType]
        panel.canCreateDirectories = true
        panel.title = "Export Clip"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        try? FileManager.default.removeItem(at: destination)

        isExporting = true
        exportProgress = 0
        exportStatusText = "Exporting clip…"
        outputURL = nil

        if clipEncodingMode == .fast {
            let asset = AVURLAsset(url: sourceURL)
            let preset = AVAssetExportPresetPassthrough

            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                isExporting = false
                exportStatusText = "Clip export failed: Unable to create passthrough export session"
                uiMessage = exportStatusText
                return
            }

            session.outputURL = destination
            session.outputFileType = selectedClipFormat.fileType
            session.shouldOptimizeForNetworkUse = true
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: clipStartSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: clipDurationSeconds, preferredTimescale: 600)
            )

            Task { [weak self] in
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
                    self.isExporting = false
                    self.exportProgress = 0
                    switch session.status {
                    case .completed:
                        self.outputURL = destination
                        self.exportStatusText = "Clip export complete: \(destination.lastPathComponent)"
                        self.uiMessage = self.exportStatusText
                    case .failed:
                        self.exportStatusText = "Clip export failed: \(session.error?.localizedDescription ?? "Unknown error")"
                        self.uiMessage = self.exportStatusText
                    case .cancelled:
                        self.exportStatusText = "Clip export cancelled"
                        self.uiMessage = self.exportStatusText
                    default:
                        self.exportStatusText = "Clip export ended with status: \(session.status.rawValue)"
                        self.uiMessage = self.exportStatusText
                    }
                }
            }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.exportProgress = 0.1
                self.exportStatusText = "Encoding compressed clip…"
            }

            guard let ffmpegURL = self.findFFmpegExecutable() else {
                await MainActor.run {
                    self.isExporting = false
                    self.exportProgress = 0
                    self.exportStatusText = "Clip export failed: No ffmpeg executable found."
                    self.uiMessage = self.exportStatusText
                }
                return
            }

            let bitrateKbps = max(1000, Int((self.clipVideoBitrateMbps * 1000.0).rounded()))
            let start = String(format: "%.3f", self.clipStartSeconds)
            let end = String(format: "%.3f", self.clipEndSeconds)
            let encodeError = await self.runProcess(
                executableURL: ffmpegURL,
                arguments: [
                    "-y",
                    "-hide_banner",
                    "-loglevel", "error",
                    "-i", sourceURL.path,
                    "-ss", start,
                    "-to", end,
                    "-map", "0:v:0",
                    "-map", "0:a?",
                    "-c:v", "libx264",
                    "-b:v", "\(bitrateKbps)k",
                    "-c:a", "aac",
                    "-b:a", "128k",
                    "-movflags", "+faststart",
                    destination.path
                ]
            )

            await MainActor.run {
                self.isExporting = false
                self.exportProgress = 0
                if let encodeError {
                    self.exportStatusText = "Clip export failed: \(encodeError)"
                    self.uiMessage = self.exportStatusText
                } else {
                    self.outputURL = destination
                    self.exportStatusText = "Clip export complete: \(destination.lastPathComponent)"
                    self.uiMessage = self.exportStatusText
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
            } catch {
                continuation.resume(returning: error.localizedDescription)
                return
            }

            process.terminationHandler = { proc in
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
}

struct SourceHeaderView: View {
    @ObservedObject var model: WorkspaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(model.sourceURL == nil ? "Choose Video" : "Change Video") {
                    model.chooseSource()
                }

                Spacer()

                if let sourceURL = model.sourceURL {
                    Text(sourceURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 0) {
                ForEach(WorkspaceTool.allCases) { tool in
                    Button {
                        model.selectedTool = tool
                    } label: {
                        ZStack {
                            Text(tool.rawValue)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(model.selectedTool == tool ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(
                            model.selectedTool == tool
                            ? Color(NSColor.windowBackgroundColor)
                            : Color.clear
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color.gray.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(12)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ToolContentView: View {
    @ObservedObject var model: WorkspaceViewModel

    var body: some View {
        Group {
            switch model.selectedTool {
            case .analyze:
                AnalyzeToolView(model: model)
            case .convert:
                ConvertToolView(model: model)
            case .clip:
                ClipToolView(model: model)
            case .inspect:
                InspectToolView(sourceURL: model.sourceURL, analysis: model.analysis, sourceInfo: model.sourceInfo)
            }
        }
    }
}

struct AnalyzeToolView: View {
    @ObservedObject var model: WorkspaceViewModel

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
                    Button(role: .destructive) {
                        model.stopAnalysis()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let analysis = model.analysis {
                Text(analysis.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let analysis = model.analysis {
                DetailView(file: analysis)
            } else {
                EmptyToolView(title: "Analyze", subtitle: "Choose a video and run black-frame analysis.")
            }
        }
    }
}

struct ConvertToolView: View {
    @ObservedObject var model: WorkspaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Audio Export") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Format", selection: $model.selectedAudioFormat) {
                        ForEach(AudioFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Bitrate (MP3)")
                        Slider(value: Binding(
                            get: { Double(model.audioBitrateKbps) },
                            set: { model.audioBitrateKbps = Int($0.rounded()) }
                        ), in: 96...320, step: 32)
                        Text("\(model.audioBitrateKbps) kbps")
                            .font(.caption.monospacedDigit())
                            .frame(width: 90, alignment: .trailing)
                    }

                    Button {
                        model.startExport()
                    } label: {
                        Label(model.isExporting ? "Exporting…" : "Export Audio", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canExport)

                    Text("M4A uses native AVFoundation export. MP3 uses ffmpeg and defaults to 128 kbps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            Spacer()
        }
    }
}

struct ClipToolView: View {
    @ObservedObject var model: WorkspaceViewModel

    @State private var player = AVPlayer()
    @State private var playheadSeconds: Double = 0
    @State private var playerDurationSeconds: Double = 0

    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    private func loadPlayerItem() {
        guard let sourceURL = model.sourceURL else {
            player.replaceCurrentItem(with: nil)
            playheadSeconds = 0
            playerDurationSeconds = 0
            return
        }
        let item = AVPlayerItem(url: sourceURL)
        player.replaceCurrentItem(with: item)
        let duration = CMTimeGetSeconds(item.asset.duration)
        playerDurationSeconds = duration.isFinite && duration > 0 ? duration : model.sourceDurationSeconds
        playheadSeconds = 0
    }

    private func seekPlayer(to time: Double) {
        let clamped = max(0, min(time, max(playerDurationSeconds, model.sourceDurationSeconds)))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playheadSeconds = clamped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.sourceURL != nil {
                InlinePlayerView(player: player)
                    .frame(minHeight: 260, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                GroupBox("Clip Range") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Playhead")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(
                                value: Binding(
                                    get: { playheadSeconds },
                                    set: { seekPlayer(to: $0) }
                                ),
                                in: 0...max(0.001, max(playerDurationSeconds, model.sourceDurationSeconds))
                            )
                            Text(formatSeconds(playheadSeconds))
                                .font(.caption.monospacedDigit())
                                .frame(width: 108, alignment: .trailing)
                        }

                        ClipRangeSelector(
                            startSeconds: Binding(
                                get: { model.clipStartSeconds },
                                set: {
                                    model.setClipStart($0)
                                }
                            ),
                            endSeconds: Binding(
                                get: { model.clipEndSeconds },
                                set: {
                                    model.setClipEnd($0)
                                }
                            ),
                            durationSeconds: max(0.001, model.sourceDurationSeconds)
                        )
                        .frame(height: 34)

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

                        HStack(spacing: 8) {
                            Text("Duration: \(formatSeconds(model.clipDurationSeconds))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Jump to Start") {
                                seekPlayer(to: model.clipStartSeconds)
                            }
                            .buttonStyle(.bordered)
                            Button("Jump to End") {
                                seekPlayer(to: model.clipEndSeconds)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Export New Clip") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Encoding", selection: $model.clipEncodingMode) {
                            ForEach(ClipEncodingMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Picker("Format", selection: $model.selectedClipFormat) {
                            ForEach(ClipFormat.allCases) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)

                        if model.clipEncodingMode == .compressed {
                            HStack {
                                Text("Video bitrate")
                                Slider(value: $model.clipVideoBitrateMbps, in: 2...20, step: 0.5)
                                Text(String(format: "%.1f Mbps", model.clipVideoBitrateMbps))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 90, alignment: .trailing)
                            }
                            .font(.caption)
                            Text("Smaller File uses H.264 video + AAC audio.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Fast uses passthrough (original codecs/bitrate).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

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
                    .padding(6)
                }
            } else {
                EmptyToolView(title: "Clip", subtitle: "Choose a source video to create a new clip from a selected range.")
            }

            Spacer()
        }
        .onAppear {
            loadPlayerItem()
        }
        .onChange(of: model.sourceURL?.path) { _ in
            loadPlayerItem()
        }
        .onReceive(timer) { _ in
            let current = CMTimeGetSeconds(player.currentTime())
            if current.isFinite {
                playheadSeconds = max(0, current)
            }
            let currentDuration = CMTimeGetSeconds(player.currentItem?.duration ?? .invalid)
            if currentDuration.isFinite && currentDuration > 0 {
                playerDurationSeconds = currentDuration
            }
        }
        .onDisappear {
            player.pause()
        }
    }
}

struct ClipRangeSelector: View {
    @Binding var startSeconds: Double
    @Binding var endSeconds: Double
    let durationSeconds: Double

    private func xPosition(for value: Double, width: CGFloat) -> CGFloat {
        guard durationSeconds > 0 else { return 0 }
        return CGFloat(min(max(0, value / durationSeconds), 1.0)) * width
    }

    private func timeValue(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        let ratio = min(max(0, x / width), 1.0)
        return Double(ratio) * durationSeconds
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let startX = xPosition(for: startSeconds, width: width)
            let endX = xPosition(for: endSeconds, width: width)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 8)
                    .offset(y: 12)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(2, endX - startX), height: 8)
                    .offset(x: startX, y: 12)

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 14, height: 14)
                    .offset(x: startX - 7, y: 9)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let newValue = min(timeValue(for: value.location.x, width: width), endSeconds)
                                startSeconds = max(0, newValue)
                            }
                    )

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 14, height: 14)
                    .offset(x: endX - 7, y: 9)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let newValue = max(timeValue(for: value.location.x, width: width), startSeconds)
                                endSeconds = min(durationSeconds, newValue)
                            }
                    )
            }
        }
    }
}

struct InspectToolView: View {
    let sourceURL: URL?
    let analysis: FileAnalysis?
    let sourceInfo: SourceMediaInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sourceURL {
                GroupBox("File") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sourceURL.lastPathComponent)
                            .font(.headline)
                        Text(sourceURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
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

                GroupBox("Audio / Container") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Audio codec: \(sourceInfo?.audioCodec ?? "—")")
                        Text("Sample rate: \(sourceInfo?.sampleRateHz.map { String(format: "%.0f Hz", $0) } ?? "—")")
                        Text("Channels: \(sourceInfo?.channels.map(String.init) ?? "—")")
                        Text("Audio bitrate: \(formatBitrate(sourceInfo?.audioBitrateBps))")
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

            Spacer()
        }
    }
}

struct OutputPanelView: View {
    @ObservedObject var model: WorkspaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let progress = model.activityProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            Text(model.activityText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.outputURL != nil {
                Button("Reveal Output in Finder") {
                    model.revealOutput()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                .frame(minHeight: 260, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        jump(by: -5)
                    } label: {
                        Label("Back 5s", systemImage: "gobackward.5")
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
                        jump(by: 5)
                    } label: {
                        Label("Forward 5s", systemImage: "goforward.5")
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

struct ContentView: View {
    @StateObject private var model = WorkspaceViewModel()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SourceHeaderView(model: model)
            ToolContentView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            OutputPanelView(model: model)
        }
        .padding(12)
        .frame(minWidth: 980, minHeight: 640)
        .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            model.handleDrop(providers: providers)
        }
    }
}

@main
struct CheckBlackFramesApp: App {
    var body: some Scene {
        WindowGroup("Check for Black Frames") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
