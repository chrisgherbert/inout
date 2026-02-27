import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI

private let picThreshold = 0.90
private let pixelBlackThreshold = 0.10
private let maxSampleDimension = 640

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

private func waveformSamples(
    for asset: AVURLAsset,
    audioTrack: AVAssetTrack,
    durationSeconds: Double,
    sampleCount: Int,
    outputSettings: [String: Any]
) -> [Double]? {
    let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false

    let reader: AVAssetReader
    do {
        reader = try AVAssetReader(asset: asset)
    } catch {
        return nil
    }
    guard reader.canAdd(output) else { return nil }
    reader.add(output)
    guard reader.startReading() else { return nil }

    var peaks = Array(repeating: 0.0, count: sampleCount)
    let bucketScale = Double(sampleCount - 1) / durationSeconds

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
        let frameStep = 1.0 / asbd.mSampleRate

        for frame in 0..<frameCount {
            let sampleTime = startTime + (Double(frame) * frameStep)
            let bucketFloat = sampleTime * bucketScale
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

    guard reader.status != .failed else { return nil }

    let maxPeak = peaks.max() ?? 0
    if maxPeak > 0 {
        return peaks.map { $0 / maxPeak }
    }
    return peaks
}

func generateWaveformSamples(for url: URL, sampleCount: Int) -> [Double] {
    guard sampleCount > 0 else { return [] }

    let asset = AVURLAsset(url: url)
    guard let audioTrack = asset.tracks(withMediaType: .audio).first else { return [] }

    let durationSeconds = CMTimeGetSeconds(asset.duration)
    guard durationSeconds.isFinite && durationSeconds > 0 else { return [] }

    let fullRateOutputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]
    // Fast path: request downmixed mono at lower sample-rate to reduce decode/processing load.
    let reducedRateOutputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 12_000,
        AVNumberOfChannelsKey: 1
    ]

    if let fast = waveformSamples(
        for: asset,
        audioTrack: audioTrack,
        durationSeconds: durationSeconds,
        sampleCount: sampleCount,
        outputSettings: reducedRateOutputSettings
    ) {
        return fast
    }

    // Fallback: keep prior full-rate behavior for assets that reject conversion settings.
    return waveformSamples(
        for: asset,
        audioTrack: audioTrack,
        durationSeconds: durationSeconds,
        sampleCount: sampleCount,
        outputSettings: fullRateOutputSettings
    ) ?? []
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

func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
