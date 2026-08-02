import AVFoundation
import CoreVideo
import Foundation

private struct BadEditFrameFingerprint {
    let luminance: [UInt8]
    let color: [UInt8]
    let blackRatio: Double
    let meanLuminance: Double
}

private struct BadEditFlashCandidate {
    let baseline: BadEditFrameFingerprint
    let start: Double
    var maximumDifference: Double
    var containsBlackFrame: Bool
}

public func detectPossibleBadEdits(
    file: URL,
    onIssueDetected: @escaping @Sendable (BadEditIssue) -> Void = { _ in },
    progressHandler: @escaping @Sendable (Double) -> Void = { _ in },
    shouldCancel: @escaping @Sendable () -> Bool = { false }
) -> Result<[BadEditIssue], DetectionError> {
    let asset = AVURLAsset(url: file)
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
        return .success([])
    }

    let assetDuration = CMTimeGetSeconds(asset.duration)
    let safeDuration = assetDuration.isFinite && assetDuration > 0 ? assetDuration : nil
    var issues = detectStreamEndingMismatch(in: asset)
    issues.forEach(onIssueDetected)

    let outputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false

    let reader: AVAssetReader
    do {
        reader = try AVAssetReader(asset: asset)
    } catch {
        return .failure(.failed("Failed to create bad-edit video reader: \(error.localizedDescription)"))
    }
    guard reader.canAdd(output) else {
        return .failure(.failed("Unable to configure bad-edit video reader output."))
    }
    reader.add(output)
    guard reader.startReading() else {
        let reason = reader.error?.localizedDescription ?? "Unknown video reader error"
        return .failure(.failed("Failed to start bad-edit scan: \(reason)"))
    }

    let similarThreshold = 0.035
    let strongDifferenceThreshold = 0.18
    let maximumFlashDuration = 0.18
    let minimumShortShotDuration = 0.20
    let maximumShortShotDuration = 0.75
    let frozenDifferenceThreshold = 0.0015
    let minimumFrozenDuration = 1.25
    var previousFingerprint: BadEditFrameFingerprint?
    var previousTimestamp: Double?
    var nominalFrameDuration = 1.0 / max(1, Double(videoTrack.nominalFrameRate))
    if !nominalFrameDuration.isFinite || nominalFrameDuration <= 0 {
        nominalFrameDuration = 1.0 / 30.0
    }
    var flashCandidate: BadEditFlashCandidate?
    var blackRunStart: Double?
    var blackRunEnd = 0.0
    var freezeStart: Double?
    var freezeFingerprint: BadEditFrameFingerprint?
    var lastFreezeIssueID: UUID?
    var lastFreezeFingerprint: BadEditFrameFingerprint?
    var lastTimestampIssueTime = -Double.greatestFiniteMagnitude
    var hardCutTimes: [Double] = []
    var previousHardCutTime: Double?
    var lastReportedProgress = -1.0
    let hasAudioTrack = !asset.tracks(withMediaType: .audio).isEmpty
    let videoProgressSpan = hasAudioTrack ? 0.72 : 0.99

    func appendIssue(_ issue: BadEditIssue) {
        let duplicate = issues.contains {
            $0.kind == issue.kind && abs($0.start - issue.start) < max(0.04, nominalFrameDuration * 1.5)
        }
        guard !duplicate else { return }
        issues.append(issue)
        onIssueDetected(issue)
    }

    func removeTransientHardCut(at time: Double) {
        guard let last = hardCutTimes.last,
              abs(last - time) <= max(0.04, nominalFrameDuration * 1.5) else { return }
        hardCutTimes.removeLast()
        previousHardCutTime = hardCutTimes.last
    }

    func finishBlackRun(at end: Double) {
        guard let start = blackRunStart else { return }
        blackRunStart = nil
        let duration = max(nominalFrameDuration, end - start)
        let isInterior = start > 0.2 && safeDuration.map { end < $0 - 0.2 } ?? true
        if isInterior && duration <= maximumFlashDuration {
            removeTransientHardCut(at: start)
            appendIssue(BadEditIssue(
                kind: .blackFlash,
                confidence: .high,
                start: start,
                end: max(start + nominalFrameDuration, end),
                title: "Brief black interruption",
                detail: badEditFrameCountDescription(duration: duration, frameDuration: nominalFrameDuration)
            ))
        }
    }

    func finishFreeze(at end: Double) {
        guard let start = freezeStart else { return }
        freezeStart = nil
        let representative = freezeFingerprint
        freezeFingerprint = nil
        let duration = max(0, end - start)
        if duration >= minimumFrozenDuration {
            if let lastFreezeIssueID,
               let previousFreezeFingerprint = lastFreezeFingerprint,
               let representative,
               let index = issues.firstIndex(where: { $0.id == lastFreezeIssueID }),
               start - issues[index].end <= max(0.25, nominalFrameDuration * 3),
               badEditFingerprintDifference(previousFreezeFingerprint, representative) <= similarThreshold {
                let previous = issues[index]
                let mergedDuration = max(0, end - previous.start)
                let merged = BadEditIssue(
                    id: previous.id,
                    kind: .frozenVideo,
                    confidence: .medium,
                    start: previous.start,
                    end: end,
                    title: "Possible frozen video",
                    detail: "The image remains nearly identical for \(String(format: "%.2f", mergedDuration)) seconds."
                )
                issues[index] = merged
                lastFreezeFingerprint = representative
                onIssueDetected(merged)
                return
            }

            let issue = BadEditIssue(
                kind: .frozenVideo,
                confidence: .medium,
                start: start,
                end: end,
                title: "Possible frozen video",
                detail: "The image remains nearly identical for \(String(format: "%.2f", duration)) seconds."
            )
            appendIssue(issue)
            lastFreezeIssueID = issue.id
            lastFreezeFingerprint = representative
        }
    }

    while let sampleBuffer = output.copyNextSampleBuffer() {
        if shouldCancel() {
            reader.cancelReading()
            return .failure(.cancelled)
        }
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard timestamp.isFinite,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let fingerprint = badEditFingerprint(pixelBuffer) else {
            continue
        }

        if let previousTimestamp {
            let delta = timestamp - previousTimestamp
            if delta > 0.001 && delta < 0.2 {
                nominalFrameDuration = (nominalFrameDuration * 0.95) + (delta * 0.05)
            } else if delta >= 0.25,
                      timestamp - lastTimestampIssueTime > 0.5 {
                lastTimestampIssueTime = timestamp
                appendIssue(BadEditIssue(
                    kind: .timestampDiscontinuity,
                    confidence: .medium,
                    start: max(0, previousTimestamp),
                    end: max(0, timestamp),
                    title: "Video timing gap",
                    detail: "There is a \(String(format: "%.2f", delta))-second gap between decoded video frames."
                ))
            } else if delta <= 0,
                      timestamp - lastTimestampIssueTime > 0.5 {
                lastTimestampIssueTime = timestamp
                appendIssue(BadEditIssue(
                    kind: .timestampDiscontinuity,
                    confidence: .high,
                    start: max(0, timestamp),
                    end: max(0, timestamp + nominalFrameDuration),
                    title: "Video timestamp discontinuity",
                    detail: "Frame timestamps do not increase normally at this point."
                ))
            }
        }

        let isBlack = fingerprint.blackRatio >= 0.95 && fingerprint.meanLuminance <= 20
        if isBlack {
            if blackRunStart == nil { blackRunStart = timestamp }
            blackRunEnd = timestamp + nominalFrameDuration
        } else if blackRunStart != nil {
            finishBlackRun(at: timestamp)
        }

        if let previousFingerprint {
            let consecutiveLuminanceDifference = badEditFingerprintDifference(previousFingerprint, fingerprint)
            let consecutiveDifference = badEditVisualDifference(previousFingerprint, fingerprint)
            if !isBlack && consecutiveLuminanceDifference <= frozenDifferenceThreshold {
                if freezeStart == nil {
                    freezeStart = previousTimestamp ?? timestamp
                    freezeFingerprint = previousFingerprint
                }
            } else if freezeStart != nil {
                finishFreeze(at: timestamp)
            }

            if var candidate = flashCandidate {
                let elapsed = timestamp - candidate.start
                let baselineDifference = badEditVisualDifference(candidate.baseline, fingerprint)
                candidate.maximumDifference = max(candidate.maximumDifference, baselineDifference)
                candidate.containsBlackFrame = candidate.containsBlackFrame || isBlack
                if baselineDifference <= similarThreshold {
                    if elapsed <= maximumFlashDuration,
                       candidate.maximumDifference >= strongDifferenceThreshold,
                       !candidate.containsBlackFrame {
                        removeTransientHardCut(at: candidate.start)
                        appendIssue(BadEditIssue(
                            kind: .visualFlash,
                            confidence: .high,
                            start: candidate.start,
                            end: timestamp,
                            title: "Brief visual interruption",
                            detail: badEditFrameCountDescription(
                                duration: max(nominalFrameDuration, elapsed),
                                frameDuration: nominalFrameDuration
                            )
                        ))
                    }
                    flashCandidate = nil
                } else if elapsed > maximumFlashDuration {
                    flashCandidate = nil
                } else {
                    flashCandidate = candidate
                }
            } else if consecutiveDifference >= strongDifferenceThreshold {
                if let previousHardCutTime {
                    let shotDuration = timestamp - previousHardCutTime
                    if shotDuration >= minimumShortShotDuration,
                       shotDuration <= maximumShortShotDuration {
                        appendIssue(BadEditIssue(
                            kind: .suspiciouslyShortShot,
                            confidence: .medium,
                            start: previousHardCutTime,
                            end: timestamp,
                            title: "Suspiciously short shot",
                            detail: "The shot between two visual cuts lasts only \(String(format: "%.2f", shotDuration)) seconds."
                        ))
                    }
                }
                if previousHardCutTime.map({ timestamp - $0 >= maximumFlashDuration }) ?? true {
                    hardCutTimes.append(timestamp)
                    previousHardCutTime = timestamp
                }
                flashCandidate = BadEditFlashCandidate(
                    baseline: previousFingerprint,
                    start: timestamp,
                    maximumDifference: consecutiveDifference,
                    containsBlackFrame: isBlack
                )
            }
        }

        previousFingerprint = fingerprint
        previousTimestamp = timestamp
        if let safeDuration {
            let progress = min(videoProgressSpan, max(0, timestamp / safeDuration) * videoProgressSpan)
            if progress - lastReportedProgress >= 0.005 {
                lastReportedProgress = progress
                progressHandler(progress)
            }
        }
    }

    if blackRunStart != nil {
        finishBlackRun(at: blackRunEnd)
    }
    if let previousTimestamp, freezeStart != nil {
        finishFreeze(at: previousTimestamp + nominalFrameDuration)
    }

    if reader.status == .failed {
        let detail = reader.error?.localizedDescription ?? "The video decoder stopped unexpectedly."
        let start = max(0, previousTimestamp ?? 0)
        appendIssue(BadEditIssue(
            kind: .decodeError,
            confidence: .high,
            start: start,
            end: start + nominalFrameDuration,
            title: "Video decode error",
            detail: detail
        ))
    }

    if hasAudioTrack {
        let audioResult = detectBadEditAudioIssues(
            file: file,
            visualEditPoints: hardCutTimes,
            progressHandler: { audioProgress in
                progressHandler(min(0.99, videoProgressSpan + (min(1, max(0, audioProgress)) * 0.27)))
            },
            shouldCancel: shouldCancel
        )
        switch audioResult {
        case .success(let audioIssues):
            audioIssues.forEach(appendIssue)
        case .failure(let error):
            return .failure(error)
        }
    }

    progressHandler(1)
    return .success(issues.sorted { $0.start < $1.start })
}

private func detectStreamEndingMismatch(in asset: AVAsset) -> [BadEditIssue] {
    guard let videoTrack = asset.tracks(withMediaType: .video).first,
          let audioTrack = asset.tracks(withMediaType: .audio).first else {
        return []
    }
    let videoEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(videoTrack.timeRange))
    let audioEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(audioTrack.timeRange))
    guard videoEnd.isFinite, audioEnd.isFinite else { return [] }
    let difference = abs(videoEnd - audioEnd)
    guard difference >= 0.75 else { return [] }
    let earlierLabel = videoEnd < audioEnd ? "Video" : "Audio"
    return [BadEditIssue(
        kind: .streamMismatch,
        confidence: .high,
        start: min(videoEnd, audioEnd),
        end: max(videoEnd, audioEnd),
        title: "Audio and video end at different times",
        detail: "\(earlierLabel) ends \(String(format: "%.2f", difference)) seconds before the other stream."
    )]
}

private func badEditFingerprint(_ pixelBuffer: CVPixelBuffer) -> BadEditFrameFingerprint? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard width > 0, height > 0 else { return nil }

    let columns = 16
    let rows = 9
    let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    var samples: [UInt8] = []
    samples.reserveCapacity(columns * rows)
    var colorSamples: [UInt8] = []
    colorSamples.reserveCapacity(columns * rows * 3)
    var blackCount = 0
    var totalLuminance = 0
    for row in 0..<rows {
        let y = min(height - 1, ((row * 2 + 1) * height) / (rows * 2))
        for column in 0..<columns {
            let x = min(width - 1, ((column * 2 + 1) * width) / (columns * 2))
            let offset = (y * bytesPerRow) + (x * 4)
            let blue = Int(bytes[offset])
            let green = Int(bytes[offset + 1])
            let red = Int(bytes[offset + 2])
            let luminance = UInt8(min(255, (red * 54 + green * 183 + blue * 19) / 256))
            samples.append(luminance)
            colorSamples.append(UInt8(red))
            colorSamples.append(UInt8(green))
            colorSamples.append(UInt8(blue))
            totalLuminance += Int(luminance)
            if luminance <= 24 { blackCount += 1 }
        }
    }
    let count = max(1, samples.count)
    return BadEditFrameFingerprint(
        luminance: samples,
        color: colorSamples,
        blackRatio: Double(blackCount) / Double(count),
        meanLuminance: Double(totalLuminance) / Double(count)
    )
}

private func badEditVisualDifference(
    _ lhs: BadEditFrameFingerprint,
    _ rhs: BadEditFrameFingerprint
) -> Double {
    guard lhs.color.count == rhs.color.count, !lhs.color.isEmpty else {
        return badEditFingerprintDifference(lhs, rhs)
    }
    let total = zip(lhs.color, rhs.color).reduce(0) {
        $0 + abs(Int($1.0) - Int($1.1))
    }
    return Double(total) / (Double(lhs.color.count) * 255.0)
}

private func badEditFingerprintDifference(
    _ lhs: BadEditFrameFingerprint,
    _ rhs: BadEditFrameFingerprint
) -> Double {
    guard lhs.luminance.count == rhs.luminance.count, !lhs.luminance.isEmpty else { return 1 }
    let total = zip(lhs.luminance, rhs.luminance).reduce(0) {
        $0 + abs(Int($1.0) - Int($1.1))
    }
    return Double(total) / (Double(lhs.luminance.count) * 255.0)
}

private func badEditFrameCountDescription(duration: Double, frameDuration: Double) -> String {
    let frameCount = max(1, Int((duration / max(0.001, frameDuration)).rounded()))
    return frameCount == 1
        ? "A single unexpected frame interrupts otherwise matching footage."
        : "\(frameCount) unexpected frames interrupt otherwise matching footage."
}
