import Foundation
import AVFoundation

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
