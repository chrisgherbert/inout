import Foundation
import AVFoundation

public func runDetection(
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
        guard asset.tracks(withMediaType: .video).first != nil else {
            return .failure(.failed("No video track found"))
        }
        let detectionResult = detectBlackFramesWithFFmpeg(
            file: file,
            mediaDuration: safeDuration,
            onSegmentDetected: onBlackSegmentDetected,
            onConsoleOutput: onConsoleOutput,
            progressHandler: { phaseProgress in
                let mappedProgress = detectAudioSilence ? (phaseProgress * 0.7) : phaseProgress
                progressHandler(min(0.99, mappedProgress))
            },
            shouldCancel: shouldCancel
        )

        switch detectionResult {
        case .success(let detectedIntervals):
            intervals = detectedIntervals
            if let lastEnd = detectedIntervals.map(\.end).max() {
                lastTimestamp = max(lastTimestamp, lastEnd)
            }
        case .failure(let error):
            return .failure(error)
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
            profanityHits = computeProfanityHits(in: cachedTranscriptSegments, profanityWords: profanityWords)
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
                profanityHits = computeProfanityHits(in: transcriptSegments, profanityWords: profanityWords)
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

private func detectBlackFramesWithFFmpeg(
    file: URL,
    mediaDuration: Double?,
    onSegmentDetected: @escaping @Sendable (Segment) -> Void,
    onConsoleOutput: @escaping @Sendable (String, String) -> Void,
    progressHandler: @escaping @Sendable (Double) -> Void,
    shouldCancel: @escaping @Sendable () -> Bool
) -> Result<[(start: Double, end: Double)], DetectionError> {
    guard let ffmpegURL = ToolDiscoveryUtilities.findExecutable(named: "ffmpeg") else {
        return .failure(.failed("No ffmpeg executable found for black frame detection."))
    }

    let filter = String(
        format: "blackdetect=d=%.3f:pix_th=%.3f:pic_th=%.3f",
        minDurationSeconds,
        pixelBlackThreshold,
        picThreshold
    )
    let arguments = [
        "-hide_banner",
        "-loglevel", "info",
        "-nostdin",
        "-i", file.path,
        "-an",
        "-sn",
        "-dn",
        "-vf", filter,
        "-f", "null",
        "-",
        "-progress", "pipe:1",
        "-nostats"
    ]

    let process = Process()
    process.executableURL = ffmpegURL
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    onConsoleOutput("$ \(ffmpegURL.path) " + arguments.joined(separator: " "), "ffmpeg")

    let lock = NSLock()
    var stdoutBuffer = ""
    var stderrBuffer = ""
    var detectedIntervals: [(start: Double, end: Double)] = []
    var lastReportedProgress = -1.0

    func handleProgressLine(_ line: String) {
        guard let mediaDuration, mediaDuration > 0 else { return }

        let progressValue: Double?
        if let outTimeSeconds = parseFFmpegProgressTime(from: line) {
            progressValue = min(1.0, max(0.0, outTimeSeconds / mediaDuration))
        } else {
            progressValue = nil
        }

        guard let progressValue else { return }
        if progressValue >= 0.99 || progressValue - lastReportedProgress >= 0.005 {
            lastReportedProgress = progressValue
            progressHandler(progressValue)
        }
    }

    func handleBlackdetectLine(_ line: String) {
        guard let interval = parseBlackdetectInterval(from: line) else { return }
        detectedIntervals.append(interval)
        let duration = max(0, interval.end - interval.start)
        if duration >= minDurationSeconds {
            onSegmentDetected(Segment(start: interval.start, end: interval.end, duration: duration))
        }
    }

    func consumeProgressData(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        stdoutBuffer.append(text)
        let lines = completeLines(from: &stdoutBuffer)
        lock.unlock()

        for line in lines {
            onConsoleOutput(line, "ffmpeg")
            handleProgressLine(line)
        }
    }

    func consumeLogData(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        stderrBuffer.append(text)
        let lines = completeLines(from: &stderrBuffer)
        lock.unlock()

        for line in lines {
            onConsoleOutput(line, "ffmpeg")
            handleBlackdetectLine(line)
        }
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        consumeProgressData(handle.availableData)
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        consumeLogData(handle.availableData)
    }

    do {
        try process.run()
    } catch {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return .failure(.failed("Failed to run ffmpeg: \(error.localizedDescription)"))
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
    consumeProgressData(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
    consumeLogData(stderrPipe.fileHandleForReading.readDataToEndOfFile())

    lock.lock()
    let trailingStdout = flushLines(from: &stdoutBuffer)
    let trailingStderr = flushLines(from: &stderrBuffer)
    lock.unlock()

    for line in trailingStdout {
        onConsoleOutput(line, "ffmpeg")
        handleProgressLine(line)
    }
    for line in trailingStderr {
        onConsoleOutput(line, "ffmpeg")
        handleBlackdetectLine(line)
    }

    if process.terminationStatus == 0 {
        progressHandler(1.0)
        return .success(detectedIntervals)
    }

    return .failure(.failed("ffmpeg exited with status \(process.terminationStatus) during black frame detection."))
}

private func parseBlackdetectInterval(from line: String) -> (start: Double, end: Double)? {
    let pattern = #"black_start:([0-9]+(?:\.[0-9]+)?)\s+black_end:([0-9]+(?:\.[0-9]+)?)\s+black_duration:([0-9]+(?:\.[0-9]+)?)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    guard let match = regex.firstMatch(in: line, range: range),
          let startRange = Range(match.range(at: 1), in: line),
          let endRange = Range(match.range(at: 2), in: line),
          let start = Double(line[startRange]),
          let end = Double(line[endRange]) else {
        return nil
    }
    return (start: start, end: end)
}

private func parseFFmpegProgressTime(from line: String) -> Double? {
    if line.hasPrefix("out_time_us="), let value = Double(line.dropFirst("out_time_us=".count)) {
        return value / 1_000_000.0
    }
    if line.hasPrefix("out_time_ms="), let value = Double(line.dropFirst("out_time_ms=".count)) {
        return value / 1_000_000.0
    }
    if line.hasPrefix("out_time=") {
        return parseTimestamp(String(line.dropFirst("out_time=".count)))
    }
    return nil
}

private func parseTimestamp(_ value: String) -> Double? {
    let pieces = value.split(separator: ":")
    guard pieces.count == 3,
          let hours = Double(pieces[0]),
          let minutes = Double(pieces[1]),
          let seconds = Double(pieces[2]) else {
        return nil
    }
    return (hours * 3600) + (minutes * 60) + seconds
}

private func completeLines(from buffer: inout String) -> [String] {
    var lines: [String] = []
    while let newlineRange = buffer.rangeOfCharacter(from: .newlines) {
        let line = String(buffer[..<newlineRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty {
            lines.append(line)
        }
        buffer.removeSubrange(..<newlineRange.upperBound)
    }
    return lines
}

private func flushLines(from buffer: inout String) -> [String] {
    let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    buffer.removeAll(keepingCapacity: false)
    return remaining.isEmpty ? [] : [remaining]
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
