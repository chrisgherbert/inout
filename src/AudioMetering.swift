import AVFoundation
import Foundation
import InOutCore
import SwiftUI

enum AudioMeterPreferences {
    static let showsMetersKey = "view.showAudioMeters"
}

struct AudioMeterValues: Equatable {
    var leftPeak: Double = 0
    var rightPeak: Double = 0
    var leftShortTerm: Double = 0
    var rightShortTerm: Double = 0
    var leftPeakHold: Double = 0
    var rightPeakHold: Double = 0
    var maximumPeak: Double = 0
    var isClipping = false

    static let zero = AudioMeterValues()
}

struct AudioLoudnessResult: Equatable {
    let integratedLUFS: Double
    let loudnessRangeLU: Double
    let truePeakDBFS: Double?
}

private let audioMeterFramesPerSecond = 60.0
private let audioMeterWindowLeadInSeconds = 2.0
private let audioMeterWindowDurationSeconds = 32.0

private struct AudioMeterFrame: Sendable {
    var leftPeak = 0.0
    var rightPeak = 0.0
    var leftRMSPower = 0.0
    var rightRMSPower = 0.0
}

private struct AudioMeterFrameAccumulator {
    var leftPeak = 0.0
    var rightPeak = 0.0
    var leftSquares = 0.0
    var rightSquares = 0.0
    var sampleCount = 0

    mutating func add(left: Double, right: Double) {
        leftPeak = max(leftPeak, abs(left))
        rightPeak = max(rightPeak, abs(right))
        leftSquares += left * left
        rightSquares += right * right
        sampleCount += 1
    }

    var frame: AudioMeterFrame {
        guard sampleCount > 0 else { return AudioMeterFrame() }
        return AudioMeterFrame(
            leftPeak: leftPeak,
            rightPeak: rightPeak,
            leftRMSPower: leftSquares / Double(sampleCount),
            rightRMSPower: rightSquares / Double(sampleCount)
        )
    }
}

private struct AudioMeterWindow: Sendable {
    let startSeconds: Double
    let framesPerSecond: Double
    let frames: [AudioMeterFrame]

    var endSeconds: Double {
        startSeconds + (Double(frames.count) / framesPerSecond)
    }

    func contains(_ time: Double) -> Bool {
        time >= startSeconds && time < endSeconds
    }

    func frame(at time: Double) -> AudioMeterFrame? {
        guard contains(time) else { return nil }
        let index = Int((time - startSeconds) * framesPerSecond)
        guard frames.indices.contains(index) else { return nil }
        return frames[index]
    }
}

private final class AudioLoudnessProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

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

private final class AudioMeterReadController: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    var cancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }
}

private enum AudioMeterWindowReader {
    static func read(
        fileURL: URL,
        startSeconds: Double,
        controller: AudioMeterReadController
    ) throws -> AudioMeterWindow {
        let asset = AVURLAsset(url: fileURL)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw AudioMeterError.noAudioTrack
        }

        let nativeFloatSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let nativeIntegerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        do {
            return try read(
                asset: asset,
                audioTrack: audioTrack,
                startSeconds: startSeconds,
                outputSettings: nativeFloatSettings,
                controller: controller
            )
        } catch {
            guard !controller.cancellationRequested, !(error is CancellationError) else {
                throw CancellationError()
            }
            return try read(
                asset: asset,
                audioTrack: audioTrack,
                startSeconds: startSeconds,
                outputSettings: nativeIntegerSettings,
                controller: controller
            )
        }
    }

    private static func read(
        asset: AVURLAsset,
        audioTrack: AVAssetTrack,
        startSeconds: Double,
        outputSettings: [String: Any],
        controller: AudioMeterReadController
    ) throws -> AudioMeterWindow {
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        let reader = try AVAssetReader(asset: asset)
        guard reader.canAdd(output) else {
            throw AudioMeterError.meterDataUnavailable("The audio track could not be decoded.")
        }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: audioMeterWindowDurationSeconds, preferredTimescale: 600)
        )
        guard !controller.cancellationRequested else {
            throw CancellationError()
        }
        guard reader.startReading() else {
            throw AudioMeterError.meterDataUnavailable(
                reader.error?.localizedDescription ?? "The audio reader could not start."
            )
        }

        let frameCount = Int(ceil(audioMeterWindowDurationSeconds * audioMeterFramesPerSecond)) + 1
        var accumulators = Array(repeating: AudioMeterFrameAccumulator(), count: frameCount)
        var decodedSampleData = false

        while !controller.cancellationRequested,
              let sampleBuffer = output.copyNextSampleBuffer() {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  stream.mSampleRate > 0,
                  let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            let bufferStart = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            guard bufferStart.isFinite else { continue }

            var byteCount = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &byteCount,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr,
                  let dataPointer,
                  byteCount > 0 else {
                continue
            }

            let channels = max(1, Int(stream.mChannelsPerFrame))
            let isFloat32 = stream.mBitsPerChannel == 32 &&
                stream.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let isSignedInt16 = stream.mBitsPerChannel == 16 &&
                stream.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
            let bytesPerSample: Int
            if isFloat32 {
                bytesPerSample = MemoryLayout<Float>.size
            } else if isSignedInt16 {
                bytesPerSample = MemoryLayout<Int16>.size
            } else {
                continue
            }
            guard stream.mFormatID == kAudioFormatLinearPCM,
                  stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                  stream.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
                continue
            }

            let bytesPerFrame = max(Int(stream.mBytesPerFrame), channels * bytesPerSample)
            let samplesInBuffer = byteCount / bytesPerFrame
            guard samplesInBuffer > 0 else { continue }

            decodedSampleData = true
            let rawSamples = UnsafeRawPointer(dataPointer)
            let secondsPerSample = 1.0 / stream.mSampleRate

            for sampleIndex in 0..<samplesInBuffer {
                let sampleTime = bufferStart + (Double(sampleIndex) * secondsPerSample)
                let frameIndex = Int((sampleTime - startSeconds) * audioMeterFramesPerSecond)
                guard accumulators.indices.contains(frameIndex) else { continue }

                let frameOffset = sampleIndex * bytesPerFrame
                let left: Double
                let right: Double
                if isFloat32 {
                    left = Double(rawSamples.load(fromByteOffset: frameOffset, as: Float.self))
                    right = channels > 1
                        ? Double(rawSamples.load(fromByteOffset: frameOffset + bytesPerSample, as: Float.self))
                        : left
                } else {
                    left = Double(rawSamples.load(fromByteOffset: frameOffset, as: Int16.self)) / 32_768.0
                    right = channels > 1
                        ? Double(rawSamples.load(fromByteOffset: frameOffset + bytesPerSample, as: Int16.self)) / 32_768.0
                        : left
                }
                accumulators[frameIndex].add(left: left, right: right)
            }
        }

        if controller.cancellationRequested {
            // AVAssetReader teardown must happen on the same thread that is
            // copying buffers. Cross-thread cancelReading can race AVFoundation.
            if reader.status == .reading {
                reader.cancelReading()
            }
            throw CancellationError()
        }
        if reader.status == .cancelled {
            throw CancellationError()
        }
        guard reader.status != .failed else {
            throw AudioMeterError.meterDataUnavailable(
                reader.error?.localizedDescription ?? "The audio reader failed."
            )
        }
        guard decodedSampleData else {
            throw AudioMeterError.meterDataUnavailable("No audio samples were available in this range.")
        }

        return AudioMeterWindow(
            startSeconds: startSeconds,
            framesPerSecond: audioMeterFramesPerSecond,
            frames: accumulators.map(\.frame)
        )
    }
}

@MainActor
final class AudioMeterPresentation: ObservableObject {
    @Published private(set) var values = AudioMeterValues.zero
    @Published private(set) var loudnessResult: AudioLoudnessResult?
    @Published private(set) var loudnessError: String?
    @Published private(set) var isAnalyzingLoudness = false
    @Published private(set) var attachmentError: String?

    private var sourceURL: URL?
    private var meterWindow: AudioMeterWindow?
    private var requestedWindowRange: Range<Double>?
    private var meterLoadTask: Task<Void, Never>?
    private var meterReadController: AudioMeterReadController?
    private var meterLoadGeneration = 0
    private var latestPlaybackTime = 0.0
    private var leftRMSPower = 0.0
    private var rightRMSPower = 0.0
    private var leftHoldStartedAt = ProcessInfo.processInfo.systemUptime
    private var rightHoldStartedAt = ProcessInfo.processInfo.systemUptime
    private var lastPublishTime = ProcessInfo.processInfo.systemUptime
    private var loudnessAnalysisGeneration = 0
    private var loudnessProcessController: AudioLoudnessProcessController?

    func prepare(fileURL: URL, at time: Double) {
        let sourceChanged = sourceURL != fileURL
        if sourceChanged {
            meterLoadGeneration &+= 1
            meterReadController?.cancel()
            meterReadController = nil
            meterLoadTask?.cancel()
            meterLoadTask = nil
            sourceURL = fileURL
            meterWindow = nil
            requestedWindowRange = nil
            values = .zero
            leftRMSPower = 0
            rightRMSPower = 0
            invalidateLoudnessAnalysis()
        }
        latestPlaybackTime = max(0, time)
        attachmentError = nil
        publishFrameForCurrentTime()
        ensureMeterWindow(for: latestPlaybackTime)
    }

    func detach(resetReadings: Bool) {
        meterLoadGeneration &+= 1
        meterReadController?.cancel()
        meterReadController = nil
        meterLoadTask?.cancel()
        meterLoadTask = nil
        sourceURL = nil
        meterWindow = nil
        requestedWindowRange = nil
        attachmentError = nil
        if resetReadings {
            values = .zero
            leftRMSPower = 0
            rightRMSPower = 0
            invalidateLoudnessAnalysis()
        }
    }

    func resetPeakHold() {
        values.leftPeakHold = values.leftPeak
        values.rightPeakHold = values.rightPeak
        values.maximumPeak = max(values.leftPeak, values.rightPeak)
        values.isClipping = false
        let now = ProcessInfo.processInfo.systemUptime
        leftHoldStartedAt = now
        rightHoldStartedAt = now
    }

    func updatePlaybackTime(_ time: Double) {
        guard sourceURL != nil, time.isFinite else { return }
        latestPlaybackTime = max(0, time)
        publishFrameForCurrentTime()
        ensureMeterWindow(for: latestPlaybackTime)
    }

    func invalidateLoudnessAnalysis() {
        loudnessAnalysisGeneration &+= 1
        loudnessProcessController?.cancel()
        loudnessProcessController = nil
        isAnalyzingLoudness = false
        loudnessResult = nil
        loudnessError = nil
    }

    func analyzeLoudness(fileURL: URL, startSeconds: Double, endSeconds: Double) {
        guard !isAnalyzingLoudness else { return }
        let start = max(0, startSeconds)
        let duration = max(0.05, endSeconds - start)
        isAnalyzingLoudness = true
        loudnessError = nil
        loudnessAnalysisGeneration &+= 1
        let generation = loudnessAnalysisGeneration
        let processController = AudioLoudnessProcessController()
        loudnessProcessController = processController

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.runLoudnessAnalysis(
                    fileURL: fileURL,
                    startSeconds: start,
                    durationSeconds: duration,
                    processController: processController
                )
            }.value
            guard let self else { return }
            guard self.loudnessAnalysisGeneration == generation else { return }
            self.loudnessProcessController = nil
            self.isAnalyzingLoudness = false
            switch result {
            case .success(let measurement):
                self.loudnessResult = measurement
            case .failure(let error):
                self.loudnessError = error.localizedDescription
            }
        }
    }

    private func ensureMeterWindow(for time: Double) {
        if let meterWindow,
           meterWindow.contains(time),
           time < meterWindow.endSeconds - 4 {
            return
        }
        if let requestedWindowRange, requestedWindowRange.contains(time) {
            return
        }
        guard let sourceURL else { return }

        let windowStart = max(0, time - audioMeterWindowLeadInSeconds)
        let windowEnd = windowStart + audioMeterWindowDurationSeconds
        requestedWindowRange = windowStart..<windowEnd
        meterLoadGeneration &+= 1
        let generation = meterLoadGeneration
        meterReadController?.cancel()
        let readController = AudioMeterReadController()
        meterReadController = readController
        meterLoadTask?.cancel()
        meterLoadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result {
                    try AudioMeterWindowReader.read(
                        fileURL: sourceURL,
                        startSeconds: windowStart,
                        controller: readController
                    )
                }
            }.value
            guard let self,
                  self.meterLoadGeneration == generation,
                  self.sourceURL == sourceURL else {
                return
            }
            self.meterLoadTask = nil
            self.meterReadController = nil
            self.requestedWindowRange = nil
            switch result {
            case .success(let window):
                self.meterWindow = window
                self.attachmentError = nil
                self.publishFrameForCurrentTime()
            case .failure(let error):
                self.attachmentError = error.localizedDescription
            }
        }
    }

    private func publishFrameForCurrentTime() {
        guard let frame = meterWindow?.frame(at: latestPlaybackTime) else {
            leftRMSPower = 0
            rightRMSPower = 0
            let cleared = AudioMeterValues(
                leftPeak: 0,
                rightPeak: 0,
                leftShortTerm: 0,
                rightShortTerm: 0,
                leftPeakHold: values.leftPeakHold,
                rightPeakHold: values.rightPeakHold,
                maximumPeak: values.maximumPeak,
                isClipping: values.isClipping
            )
            if cleared != values {
                values = cleared
            }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let deltaTime = min(0.1, max(1.0 / 240.0, now - lastPublishTime))
        lastPublishTime = now
        let leftPeak = updatedDisplayedLevel(
            current: values.leftPeak,
            target: frame.leftPeak,
            deltaTime: deltaTime
        )
        let rightPeak = updatedDisplayedLevel(
            current: values.rightPeak,
            target: frame.rightPeak,
            deltaTime: deltaTime
        )
        let leftHold = updatedPeakHold(
            current: frame.leftPeak,
            previous: values.leftPeakHold,
            holdStartedAt: &leftHoldStartedAt,
            now: now,
            deltaTime: deltaTime
        )
        let rightHold = updatedPeakHold(
            current: frame.rightPeak,
            previous: values.rightPeakHold,
            holdStartedAt: &rightHoldStartedAt,
            now: now,
            deltaTime: deltaTime
        )
        let rmsWeight = exp(-deltaTime / 0.4)
        leftRMSPower = (leftRMSPower * rmsWeight) + (frame.leftRMSPower * (1 - rmsWeight))
        rightRMSPower = (rightRMSPower * rmsWeight) + (frame.rightRMSPower * (1 - rmsWeight))
        let next = AudioMeterValues(
            leftPeak: leftPeak,
            rightPeak: rightPeak,
            leftShortTerm: sqrt(max(0, leftRMSPower)),
            rightShortTerm: sqrt(max(0, rightRMSPower)),
            leftPeakHold: leftHold,
            rightPeakHold: rightHold,
            maximumPeak: max(values.maximumPeak, frame.leftPeak, frame.rightPeak),
            isClipping: values.isClipping || frame.leftPeak >= 0.9999 || frame.rightPeak >= 0.9999
        )
        if next != values {
            values = next
        }
    }

    private func updatedPeakHold(
        current: Double,
        previous: Double,
        holdStartedAt: inout TimeInterval,
        now: TimeInterval,
        deltaTime: TimeInterval
    ) -> Double {
        if current >= previous {
            holdStartedAt = now
            return current
        }
        guard now - holdStartedAt > 1.25 else { return previous }
        let previousDB = amplitudeToDecibels(previous)
        let currentDB = amplitudeToDecibels(current)
        let decayedDB = previousDB - (24.0 * deltaTime)
        return decibelsToAmplitude(max(currentDB, decayedDB))
    }

    private func updatedDisplayedLevel(
        current: Double,
        target: Double,
        deltaTime: TimeInterval
    ) -> Double {
        if target >= current {
            // A short attack smooths buffer boundaries without hiding transients;
            // maximum peak and clipping still use the unfiltered tap values.
            let attack = 1 - exp(-deltaTime / 0.012)
            return current + ((target - current) * attack)
        }

        let currentDB = amplitudeToDecibels(current)
        let targetDB = amplitudeToDecibels(target)
        return decibelsToAmplitude(max(targetDB, currentDB - (36 * deltaTime)))
    }

    nonisolated private static func runLoudnessAnalysis(
        fileURL: URL,
        startSeconds: Double,
        durationSeconds: Double,
        processController: AudioLoudnessProcessController
    ) -> Result<AudioLoudnessResult, Error> {
        guard let ffmpegURL = ToolDiscoveryUtilities.findExecutable(named: "ffmpeg") else {
            return .failure(AudioMeterError.ffmpegUnavailable)
        }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner",
            "-nostdin",
            "-ss", String(format: "%.6f", startSeconds),
            "-t", String(format: "%.6f", durationSeconds),
            "-i", fileURL.path,
            "-vn",
            "-af", "ebur128=peak=true:framelog=quiet",
            "-f", "null",
            "-"
        ]
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe

        do {
            guard processController.install(process) else {
                return .failure(CancellationError())
            }
            defer { processController.finish(process) }
            try process.run()
            processController.terminateIfCancelled(process)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                return .failure(AudioMeterError.analysisFailed(Self.lastUsefulLine(in: output)))
            }
            return Self.parseLoudnessSummary(output)
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func parseLoudnessSummary(
        _ output: String
    ) -> Result<AudioLoudnessResult, Error> {
        let summary: String
        if let range = output.range(of: "Summary:", options: .backwards) {
            summary = String(output[range.lowerBound...])
        } else {
            summary = output
        }

        guard let integrated = firstCapture(
            pattern: #"\bI:\s*(-?[0-9]+(?:\.[0-9]+)?)\s+LUFS"#,
            in: summary
        ), let loudnessRange = firstCapture(
            pattern: #"\bLRA:\s*(-?[0-9]+(?:\.[0-9]+)?)\s+LU"#,
            in: summary
        ) else {
            return .failure(AudioMeterError.invalidLoudnessOutput)
        }
        let truePeak = firstCapture(
            pattern: #"\bPeak:\s*(-?[0-9]+(?:\.[0-9]+)?)\s+dBFS"#,
            in: summary
        )
        return .success(
            AudioLoudnessResult(
                integratedLUFS: integrated,
                loudnessRangeLU: loudnessRange,
                truePeakDBFS: truePeak
            )
        )
    }

    nonisolated private static func firstCapture(pattern: String, in text: String) -> Double? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[range])
    }

    nonisolated private static func lastUsefulLine(in output: String) -> String {
        output
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty }) ?? "Unknown FFmpeg error."
    }
}

private enum AudioMeterError: LocalizedError {
    case noAudioTrack
    case meterDataUnavailable(String)
    case ffmpegUnavailable
    case analysisFailed(String)
    case invalidLoudnessOutput

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "No audio track is available."
        case .meterDataUnavailable(let detail):
            return "Audio metering is unavailable: \(detail)"
        case .ffmpegUnavailable:
            return "The bundled FFmpeg tool is unavailable."
        case .analysisFailed(let detail):
            return "Audio analysis failed: \(detail)"
        case .invalidLoudnessOutput:
            return "Audio analysis did not return loudness measurements."
        }
    }
}

func amplitudeToDecibels(_ amplitude: Double, floor: Double = -60) -> Double {
    guard amplitude > 0 else { return floor }
    return max(floor, 20 * log10(amplitude))
}

private func decibelsToAmplitude(_ decibels: Double) -> Double {
    pow(10, decibels / 20)
}

struct AudioMeterRailView: View {
    @ObservedObject var presentation: AudioMeterPresentation
    let isPlaying: Bool
    let fileURL: URL?
    let clipStartSeconds: Double
    let clipEndSeconds: Double

    @State private var showsDetails = false

    var body: some View {
        Button {
            showsDetails.toggle()
        } label: {
            AudioMeterRailContent(values: presentation.values, isPlaying: isPlaying)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("Show audio level details")
        .accessibilityLabel("Audio levels")
        .popover(isPresented: $showsDetails, arrowEdge: .leading) {
            AudioMeterDetailsView(
                presentation: presentation,
                canAnalyze: fileURL != nil,
                analyze: {
                    guard let fileURL else { return }
                    presentation.analyzeLoudness(
                        fileURL: fileURL,
                        startSeconds: clipStartSeconds,
                        endSeconds: clipEndSeconds
                    )
                }
            )
        }
    }
}

private struct AudioMeterRailContent: View {
    let values: AudioMeterValues
    let isPlaying: Bool

    private let scaleValues: [Double] = [0, -6, -12, -24, -48]

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 4) {
                meterBar(
                    level: values.leftPeak,
                    currentPeak: values.leftPeak,
                    heldPeak: values.leftPeakHold
                )
                meterBar(
                    level: values.rightPeak,
                    currentPeak: values.rightPeak,
                    heldPeak: values.rightPeakHold
                )

                GeometryReader { geometry in
                    ForEach(scaleValues, id: \.self) { value in
                        Text("\(Int(value))")
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .position(
                                x: geometry.size.width / 2,
                                y: meterPosition(decibels: value, height: geometry.size.height)
                            )
                    }
                }
                .frame(width: 17)
            }

            HStack(spacing: 8) {
                Text("L")
                Text("R")
            }
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.trailing, 17)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.74),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(values.isClipping ? Color.red.opacity(0.75) : Color.primary.opacity(0.12), lineWidth: 0.75)
        }
        .opacity(isPlaying ? 1 : 0.78)
    }

    private func meterBar(level: Double, currentPeak: Double, heldPeak: Double) -> some View {
        GeometryReader { geometry in
            let levelHeight = meterHeight(amplitude: level, totalHeight: geometry.size.height)
            let currentPeakY = geometry.size.height - meterHeight(
                amplitude: currentPeak,
                totalHeight: geometry.size.height
            )
            let heldPeakY = geometry.size.height - meterHeight(
                amplitude: heldPeak,
                totalHeight: geometry.size.height
            )
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.black.opacity(0.56))

                LinearGradient(
                    stops: [
                        .init(color: Color.green.opacity(0.85), location: 0),
                        .init(color: Color.green, location: 0.72),
                        .init(color: Color.yellow, location: 0.88),
                        .init(color: Color.red, location: 1)
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: levelHeight)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .animation(.linear(duration: 0.045), value: levelHeight)

                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(height: 1)
                    .position(x: geometry.size.width / 2, y: currentPeakY)
                    .animation(.linear(duration: 0.045), value: currentPeakY)

                Rectangle()
                    .fill(Color.white.opacity(0.92))
                    .frame(height: 1)
                    .position(x: geometry.size.width / 2, y: heldPeakY)
                    .animation(.linear(duration: 0.045), value: heldPeakY)
            }
        }
        .frame(width: 7)
    }

    private func meterHeight(amplitude: Double, totalHeight: CGFloat) -> CGFloat {
        let normalized = (amplitudeToDecibels(amplitude) + 60) / 60
        return totalHeight * CGFloat(min(1, max(0, normalized)))
    }

    private func meterPosition(decibels: Double, height: CGFloat) -> CGFloat {
        let normalized = CGFloat((decibels + 60) / 60)
        return max(4, min(height - 4, height * (1 - normalized)))
    }
}

private struct AudioMeterDetailsView: View {
    @ObservedObject var presentation: AudioMeterPresentation
    let canAnalyze: Bool
    let analyze: () -> Void

    private var currentPeak: Double {
        max(presentation.values.leftPeak, presentation.values.rightPeak)
    }

    private var shortTerm: Double {
        max(presentation.values.leftShortTerm, presentation.values.rightShortTerm)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio Levels")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                detailRow("Current Peak", value: formatAmplitude(currentPeak))
                detailRow("Current RMS", value: formatAmplitude(shortTerm))
                detailRow("Maximum Peak", value: formatAmplitude(presentation.values.maximumPeak))
                detailRow(
                    "Integrated",
                    value: presentation.loudnessResult.map { String(format: "%.1f LUFS", $0.integratedLUFS) } ?? "Not analyzed"
                )
                detailRow(
                    "Loudness Range",
                    value: presentation.loudnessResult.map { String(format: "%.1f LU", $0.loudnessRangeLU) } ?? "Not analyzed"
                )
            }

            if let truePeak = presentation.loudnessResult?.truePeakDBFS {
                Text(String(format: "Measured true peak: %.1f dBFS", truePeak))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = presentation.attachmentError ?? presentation.loudnessError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Reset Peak Hold") {
                    presentation.resetPeakHold()
                }
                Spacer()
                Button(presentation.isAnalyzingLoudness ? "Analyzing..." : "Analyze Clip", action: analyze)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAnalyze || presentation.isAnalyzingLoudness)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    @ViewBuilder
    private func detailRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func formatAmplitude(_ amplitude: Double) -> String {
        guard amplitude > 0 else { return "-60.0 dBFS" }
        return String(format: "%.1f dBFS", amplitudeToDecibels(amplitude))
    }
}
