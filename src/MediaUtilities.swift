import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import InOutCore
import SwiftUI

private let picThreshold = 0.90
private let pixelBlackThreshold = 0.10
private let maxSampleDimension = 640
private let quickSampleDimension = 160
private let quickDecisionMargin = 0.08

func formatSeconds(_ value: Double) -> String {
    InOutCore.formatSeconds(value)
}

func formatDisplayTimecode(
    _ value: Double,
    style: TimecodeFormatConfiguration,
    frameRate: Double? = nil,
    mediaDuration: Double? = nil
) -> String {
    InOutCore.formatDisplayTimecode(
        value,
        format: style,
        frameRate: frameRate,
        mediaDuration: mediaDuration
    )
}

struct DisplayTimecodeText: View {
    let seconds: Double
    @Environment(\.timecodeDisplayStyle) private var style
    @Environment(\.timecodeFrameRate) private var frameRate
    @Environment(\.timecodeMediaDuration) private var mediaDuration

    var body: some View {
        Text(formatDisplayTimecode(
            seconds,
            style: style,
            frameRate: frameRate,
            mediaDuration: mediaDuration
        ))
    }
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

func parseTimecode(
    _ value: String,
    style: TimecodeFormatConfiguration? = nil,
    frameRate: Double? = nil,
    mediaDuration: Double? = nil
) -> Double? {
    if let style {
        return InOutCore.parseTimecode(
            value,
            format: style,
            frameRate: frameRate,
            mediaDuration: mediaDuration
        )
    }
    return InOutCore.parseTimecode(value, frameRate: frameRate)
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

    let videoTracks = asset.tracks(withMediaType: .video)
    info.videoStreamCount = videoTracks.count
    if let videoTrack = videoTracks.first {
        if let timing = mediaContentTimeRange(for: videoTrack) {
            info.videoStartSeconds = timing.start
            info.videoDurationSeconds = timing.duration
        }

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

    let audioTracks = asset.tracks(withMediaType: .audio)
    info.audioStreamCount = audioTracks.count
    if let audioTrack = audioTracks.first {
        if let timing = mediaContentTimeRange(for: audioTrack) {
            info.audioStartSeconds = timing.start
            info.audioDurationSeconds = timing.duration
        }

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

final class WaveformGenerationController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    var cancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func install(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        self.process = process
        return true
    }

    func finish(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func terminateIfCancelled(_ process: Process) {
        lock.lock()
        let shouldTerminate = isCancelled
        lock.unlock()
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let process = process
        self.process = nil
        lock.unlock()

        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

private func waveformDecodeSampleRate(durationSeconds: Double, sampleCount: Int) -> Int {
    // Preserve several decoded values per displayed bucket without producing a
    // full-rate PCM copy of a long recording.
    let desiredRate = (Double(sampleCount) * 8.0) / durationSeconds
    return [250, 500, 1_000, 2_000, 4_000, 8_000, 12_000]
        .first(where: { Double($0) >= desiredRate }) ?? 12_000
}

func generateWaveformSamples(
    for url: URL,
    durationSeconds: Double,
    sampleCount: Int,
    controller: WaveformGenerationController
) -> [Double] {
    guard sampleCount > 0,
          durationSeconds.isFinite,
          durationSeconds > 0,
          !controller.cancellationRequested,
          let ffmpegURL = ToolDiscoveryUtilities.findExecutable(named: "ffmpeg") else {
        return []
    }

    let sampleRate = waveformDecodeSampleRate(
        durationSeconds: durationSeconds,
        sampleCount: sampleCount
    )
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = ffmpegURL
    process.arguments = [
        "-hide_banner",
        "-loglevel", "error",
        "-nostdin",
        "-i", url.path,
        "-map", "0:a:0",
        "-vn",
        "-sn",
        "-dn",
        "-ac", "1",
        "-ar", String(sampleRate),
        "-c:a", "pcm_f32le",
        "-f", "f32le",
        "pipe:1"
    ]
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice

    guard controller.install(process) else { return [] }
    defer { controller.finish(process) }

    do {
        try process.run()
    } catch {
        return []
    }
    controller.terminateIfCancelled(process)

    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard !controller.cancellationRequested,
          process.terminationStatus == 0,
          data.count >= MemoryLayout<Float>.stride else {
        return []
    }

    var peaks = Array(repeating: 0.0, count: sampleCount)
    let expectedFrameCount = max(1, Int((durationSeconds * Double(sampleRate)).rounded(.up)))

    data.withUnsafeBytes { rawBuffer in
        let samples = rawBuffer.bindMemory(to: Float.self)
        for index in samples.indices {
            if index.isMultiple(of: 4_096), controller.cancellationRequested { return }
            let bucket = min(sampleCount - 1, (index * sampleCount) / expectedFrameCount)
            let value = Double(abs(samples[index]))
            if value.isFinite {
                peaks[bucket] = max(peaks[bucket], value)
            }
        }
    }

    guard !controller.cancellationRequested else { return [] }
    let maximumPeak = peaks.max() ?? 0
    guard maximumPeak > 0 else { return peaks }
    return peaks.map { $0 / maximumPeak }
}

private func blackPixelRatio(
    imageBuffer: CVImageBuffer,
    maxDimension: Int
) -> Double {
    guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
        return 0
    }

    let width = CVPixelBufferGetWidth(imageBuffer)
    let height = CVPixelBufferGetHeight(imageBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
    if width <= 0 || height <= 0 { return 0 }

    let xStep = max(1, width / maxDimension)
    let yStep = max(1, height / maxDimension)
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

    guard sampledPixels > 0 else { return 0 }
    return Double(darkPixels) / Double(sampledPixels)
}

func isFrameMostlyBlack(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
        return false
    }

    CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

    // Phase 1 optimization:
    // 1) cheap coarse scan for obvious black/non-black frames
    // 2) fall back to dense scan only for borderline frames
    let quickRatio = blackPixelRatio(imageBuffer: imageBuffer, maxDimension: quickSampleDimension)
    if quickRatio >= (picThreshold + quickDecisionMargin) {
        return true
    }
    if quickRatio <= (picThreshold - quickDecisionMargin) {
        return false
    }

    let ratio = blackPixelRatio(imageBuffer: imageBuffer, maxDimension: maxSampleDimension)
    return ratio >= picThreshold
}

func buildSegments(blackIntervals: [(start: Double, end: Double)], minDuration: Double) -> [Segment] {
    blackIntervals.compactMap { interval in
        let duration = max(0, interval.end - interval.start)
        guard duration >= minDuration else { return nil }
        return Segment(start: interval.start, end: interval.end, duration: duration)
    }
}

func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
