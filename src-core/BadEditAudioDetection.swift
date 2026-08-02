import AVFoundation
import Foundation

func detectBadEditAudioIssues(
    file: URL,
    visualEditPoints: [Double],
    progressHandler: @escaping @Sendable (Double) -> Void = { _ in },
    shouldCancel: @escaping @Sendable () -> Bool = { false }
) -> Result<[BadEditIssue], DetectionError> {
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
        return .failure(.failed("Failed to create bad-edit audio reader: \(error.localizedDescription)"))
    }
    guard reader.canAdd(output) else {
        return .failure(.failed("Unable to configure bad-edit audio reader output."))
    }
    reader.add(output)
    guard reader.startReading() else {
        let reason = reader.error?.localizedDescription ?? "Unknown audio reader error"
        return .failure(.failed("Failed to start bad-edit audio scan: \(reason)"))
    }

    let duration = CMTimeGetSeconds(asset.duration)
    let safeDuration = duration.isFinite && duration > 0 ? duration : nil
    let sortedEditPoints = visualEditPoints.sorted()
    var issues: [BadEditIssue] = []
    var previousSamples: [Double] = []
    var smoothedJump = 0.01
    var lastIssueTime = -Double.greatestFiniteMagnitude
    var lastTimestamp = 0.0

    while let sampleBuffer = output.copyNextSampleBuffer() {
        if shouldCancel() {
            reader.cancelReading()
            return .failure(.cancelled)
        }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate > 0,
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            continue
        }
        let startTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard startTime.isFinite else { continue }

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

        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let bytesPerFrame = max(Int(asbd.mBytesPerFrame), channels * MemoryLayout<Int16>.size)
        let frameCount = length / bytesPerFrame
        guard frameCount > 0 else { continue }
        if previousSamples.count != channels {
            previousSamples = Array(repeating: 0, count: channels)
        }

        let samples = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Int16.self)
        let frameStep = 1.0 / asbd.mSampleRate
        for frame in 0..<frameCount {
            let sampleTime = startTime + (Double(frame) * frameStep)
            var maximumJump = 0.0
            var maximumPeak = 0.0
            var previousPeak = 0.0
            for channel in 0..<channels {
                let value = Double(samples[(frame * channels) + channel]) / Double(Int16.max)
                maximumJump = max(maximumJump, abs(value - previousSamples[channel]))
                maximumPeak = max(maximumPeak, abs(value))
                previousPeak = max(previousPeak, abs(previousSamples[channel]))
                previousSamples[channel] = value
            }

            let nearbyEdit = nearestEditPoint(to: sampleTime, in: sortedEditPoints, tolerance: 0.025)
            let enoughTimeSinceLastIssue = sampleTime - lastIssueTime >= 0.20
            if enoughTimeSinceLastIssue,
               let editTime = nearbyEdit,
               maximumJump >= max(0.42, smoothedJump * 4),
               (min(maximumPeak, previousPeak) >= 0.06 || maximumPeak >= 0.985) {
                lastIssueTime = sampleTime
                issues.append(BadEditIssue(
                    kind: .audioClippingAtEditPoint,
                    confidence: .medium,
                    start: max(0, editTime - 0.025),
                    end: editTime + 0.025,
                    title: "Possible clipped audio at edit",
                    detail: "The waveform changes abruptly at a visual cut, which may indicate audio clipped mid-sound."
                ))
            } else if enoughTimeSinceLastIssue,
                      maximumJump >= max(0.72, smoothedJump * 6),
                      min(maximumPeak, previousPeak) >= 0.10 {
                lastIssueTime = sampleTime
                issues.append(BadEditIssue(
                    kind: .abruptAudioDiscontinuity,
                    confidence: .medium,
                    start: max(0, sampleTime - 0.015),
                    end: sampleTime + 0.015,
                    title: "Abrupt audio discontinuity",
                    detail: "An unusually large sample-to-sample waveform jump occurs here."
                ))
            }
            smoothedJump = (smoothedJump * 0.995) + (maximumJump * 0.005)
            lastTimestamp = sampleTime
        }

        if let safeDuration {
            progressHandler(min(0.99, max(0, lastTimestamp / safeDuration)))
        }
    }

    if reader.status == .failed {
        let reason = reader.error?.localizedDescription ?? "Unknown audio reader failure"
        return .failure(.failed("Bad-edit audio scan failed: \(reason)"))
    }
    progressHandler(1)
    return .success(issues)
}

private func nearestEditPoint(to time: Double, in editPoints: [Double], tolerance: Double) -> Double? {
    guard !editPoints.isEmpty else { return nil }
    var lower = 0
    var upper = editPoints.count
    while lower < upper {
        let middle = (lower + upper) / 2
        if editPoints[middle] < time {
            lower = middle + 1
        } else {
            upper = middle
        }
    }
    let candidates = [lower - 1, lower]
        .filter { editPoints.indices.contains($0) }
        .map { editPoints[$0] }
    return candidates.min(by: { abs($0 - time) < abs($1 - time) }).flatMap {
        abs($0 - time) <= tolerance ? $0 : nil
    }
}
