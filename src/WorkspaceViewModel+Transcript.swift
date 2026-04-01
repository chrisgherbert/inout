import Foundation
import AppKit
import InOutCore

final class TranscriptGenerationRelay {
    private final class ProgressBatcher {
        private let queue = DispatchQueue(label: "inout.transcript.progress-batcher")
        private let flushInterval: TimeInterval
        private let disableBatching: Bool
        private let sink: @Sendable (Double) -> Void
        private var latestProgress: Double?
        private var flushScheduled = false

        init(
            disableBatching: Bool,
            flushInterval: TimeInterval = 0.08,
            sink: @escaping @Sendable (Double) -> Void
        ) {
            self.disableBatching = disableBatching
            self.flushInterval = flushInterval
            self.sink = sink
        }

        func enqueue(_ progress: Double) {
            if disableBatching {
                sink(progress)
                return
            }

            queue.async {
                self.latestProgress = progress
                guard !self.flushScheduled else { return }
                self.flushScheduled = true
                self.queue.asyncAfter(deadline: .now() + self.flushInterval) {
                    self.flushLocked()
                }
            }
        }

        func flushNow() {
            if disableBatching { return }
            let progress = queue.sync {
                let progress = latestProgress
                latestProgress = nil
                flushScheduled = false
                return progress
            }
            guard let progress else { return }
            sink(progress)
        }

        private func flushLocked() {
            let progress = latestProgress
            latestProgress = nil
            flushScheduled = false
            guard let progress else { return }
            sink(progress)
        }
    }

    private final class SegmentBatcher {
        private let queue = DispatchQueue(label: "inout.transcript.segment-batcher")
        private let flushInterval: TimeInterval
        private let disableBatching: Bool
        private let sink: @Sendable ([TranscriptSegment]) -> Void
        private var pendingSegments: [TranscriptSegment] = []
        private var flushScheduled = false

        init(
            disableBatching: Bool,
            flushInterval: TimeInterval = 0.10,
            sink: @escaping @Sendable ([TranscriptSegment]) -> Void
        ) {
            self.disableBatching = disableBatching
            self.flushInterval = flushInterval
            self.sink = sink
        }

        func enqueue(_ segment: TranscriptSegment) {
            if disableBatching {
                sink([segment])
                return
            }

            queue.async {
                self.pendingSegments.append(segment)
                guard !self.flushScheduled else { return }
                self.flushScheduled = true
                self.queue.asyncAfter(deadline: .now() + self.flushInterval) {
                    self.flushLocked()
                }
            }
        }

        func flushNow() {
            if disableBatching { return }
            let segments = queue.sync {
                let segments = pendingSegments
                pendingSegments.removeAll(keepingCapacity: true)
                flushScheduled = false
                return segments
            }
            guard !segments.isEmpty else { return }
            sink(segments)
        }

        private func flushLocked() {
            let segments = pendingSegments
            pendingSegments.removeAll(keepingCapacity: true)
            flushScheduled = false
            guard !segments.isEmpty else { return }
            sink(segments)
        }
    }

    private final class ConsoleBatcher {
        private let queue = DispatchQueue(label: "inout.transcript.console-batcher")
        private let flushInterval: TimeInterval
        private let disableBatching: Bool
        private let sink: @Sendable (String) -> Void
        private var pendingChunk = ""
        private var flushScheduled = false

        init(
            disableBatching: Bool,
            flushInterval: TimeInterval = 0.10,
            sink: @escaping @Sendable (String) -> Void
        ) {
            self.disableBatching = disableBatching
            self.flushInterval = flushInterval
            self.sink = sink
        }

        func enqueue(line: String, source: String) {
            let cleaned = line.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            let rendered = source.isEmpty ? cleaned : "[\(source)] \(cleaned)"

            if disableBatching {
                sink(rendered)
                return
            }

            queue.async {
                if self.pendingChunk.isEmpty {
                    self.pendingChunk = rendered
                } else {
                    self.pendingChunk += "\n" + rendered
                }

                guard !self.flushScheduled else { return }
                self.flushScheduled = true
                self.queue.asyncAfter(deadline: .now() + self.flushInterval) {
                    self.flushLocked()
                }
            }
        }

        func flushNow() {
            if disableBatching { return }
            let chunk = queue.sync {
                let chunk = pendingChunk
                pendingChunk = ""
                flushScheduled = false
                return chunk
            }
            guard !chunk.isEmpty else { return }
            sink(chunk)
        }

        private func flushLocked() {
            let chunk = pendingChunk
            pendingChunk = ""
            flushScheduled = false
            guard !chunk.isEmpty else { return }
            sink(chunk)
        }
    }

    private let progressBatcher: ProgressBatcher
    private let segmentBatcher: SegmentBatcher
    private let consoleBatcher: ConsoleBatcher?

    init(
        disableBatching: Bool,
        captureConsoleOutput: Bool,
        progressSink: @escaping @Sendable (Double) -> Void,
        segmentSink: @escaping @Sendable ([TranscriptSegment]) -> Void,
        consoleSink: @escaping @Sendable (String) -> Void
    ) {
        progressBatcher = ProgressBatcher(disableBatching: disableBatching, sink: progressSink)
        segmentBatcher = SegmentBatcher(disableBatching: disableBatching, sink: segmentSink)
        if captureConsoleOutput {
            consoleBatcher = ConsoleBatcher(disableBatching: disableBatching, sink: consoleSink)
        } else {
            consoleBatcher = nil
        }
    }

    func enqueueProgress(_ progress: Double) {
        progressBatcher.enqueue(progress)
    }

    func enqueueSegment(_ segment: TranscriptSegment) {
        segmentBatcher.enqueue(segment)
    }

    func enqueueConsole(line: String, source: String) {
        consoleBatcher?.enqueue(line: line, source: source)
    }

    func flushNow() {
        progressBatcher.flushNow()
        segmentBatcher.flushNow()
        consoleBatcher?.flushNow()
    }
}

extension WorkspaceViewModel {
    func generateTranscript() {
        guard let url = sourceURL else { return }
        guard !hasCachedTranscript else { return }
        guard hasAudioTrack else {
            transcriptStatusText = "No audio track available for transcript."
            return
        }
        guard whisperTranscriptionAvailable else {
            transcriptStatusText = "Whisper binary/model is not bundled in this app build."
            return
        }
        guard !isAnalyzing && !isExporting && !isGeneratingTranscript else { return }

        prepareTranscriptGenerationState(
            fileName: url.lastPathComponent,
            beginDirectJobTrackingForTranscript: true,
            clearConsole: true,
            resetProgress: true
        )

        analyzeTask = Task { [weak self] in
            guard let self else { return }
            let flag = cancelFlag
            let result = await self.runSharedTranscriptGeneration(
                file: url,
                fileName: url.lastPathComponent,
                progressRange: 0.0...1.0,
                captureConsoleOutput: self.showActivityConsole,
                shouldCancel: {
                    flag.isCancelled()
                }
            )

            await MainActor.run {
                self.applyTranscriptGenerationResult(result)
            }
        }
    }

    func generateTranscriptFromInspect() {
        generateTranscript()
    }

    func setInteractiveTimelineScrubbing(_ active: Bool) {
        guard isInteractiveTimelineScrubbing != active else { return }
        isInteractiveTimelineScrubbing = active
        if !active {
            scheduleTranscriptPreviewFlush(immediate: true)
        }
    }

    func resetTranscriptPreviewPipeline() {
        transcriptPreviewFlushTask?.cancel()
        transcriptPreviewFlushTask = nil
        transcriptGenerationRelay = nil
        pendingTranscriptPreviewSegments.removeAll(keepingCapacity: false)
    }

    func startBenchmarkTranscriptPreviewStress(ratePerSecond: Double) {
        guard PlayheadDiagnostics.shared.isEnabled else { return }
        stopBenchmarkTranscriptPreviewStress()
        resetTranscriptPreviewPipeline()
        transcriptSegments = []
        hasCachedTranscript = false
        isGeneratingTranscript = true
        transcriptStatusText = "Generating transcript…"
        analyzeStatusText = transcriptStatusText
        uiMessage = transcriptStatusText
        let relay = TranscriptGenerationRelay(
            disableBatching: PlayheadBenchmarkConfig.shared.disableTranscriptPreviewBatching,
            captureConsoleOutput: false,
            progressSink: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.setAnalyzeProgress(progress, fileName: "benchmark-transcript")
                }
            },
            segmentSink: { [weak self] segments in
                Task { @MainActor [weak self] in
                    self?.enqueueGeneratedTranscriptPreviewSegments(segments)
                }
            },
            consoleSink: { _ in }
        )
        transcriptGenerationRelay = relay

        let interval = max(0.02, 1.0 / max(1.0, ratePerSecond))
        benchmarkTranscriptStressTask = Task {
            var index = 0
            while !Task.isCancelled {
                let segment = Self.syntheticBenchmarkTranscriptSegment(index: index)
                let progress = min(0.99, Double(index % 100) / 100.0)
                relay.enqueueSegment(segment)
                relay.enqueueProgress(progress)
                index += 1
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopBenchmarkTranscriptPreviewStress() {
        benchmarkTranscriptStressTask?.cancel()
        benchmarkTranscriptStressTask = nil
        if isGeneratingTranscript {
            transcriptGenerationRelay?.flushNow()
            flushPendingTranscriptPreviewSegments()
        }
        isGeneratingTranscript = false
        resetTranscriptPreviewPipeline()
    }

    func prepareTranscriptGenerationState(
        fileName: String,
        beginDirectJobTrackingForTranscript: Bool,
        clearConsole: Bool,
        resetProgress: Bool
    ) {
        if beginDirectJobTrackingForTranscript {
            _ = beginDirectJobTracking(
                fileName: fileName,
                summary: "Generate Transcript",
                subtitle: "Whisper"
            )
        }

        isGeneratingTranscript = true
        isAnalyzing = true
        lastActivityState = .running
        wasCancelled = false
        transcriptSegments = []
        resetTranscriptPreviewPipeline()
        hasCachedTranscript = false
        if resetProgress {
            analyzeProgress = 0
        }
        if clearConsole {
            clearActivityConsole()
        }
        appendActivityConsole("Transcript generation started", source: "analysis")
        analyzePhaseText = "Transcribing audio"
        scheduleAnalyzeFeedbackUpdate(progress: analyzeProgress, fileName: fileName, immediate: true)
        transcriptStatusText = "Generating transcript…"
        analyzeStatusText = transcriptStatusText
        uiMessage = transcriptStatusText
        cancelFlag.reset()
    }

    func runSharedTranscriptGeneration(
        file: URL,
        fileName: String,
        progressRange: ClosedRange<Double>,
        captureConsoleOutput: Bool,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async -> Result<[TranscriptSegment], DetectionError> {
        let relay = TranscriptGenerationRelay(
            disableBatching: PlayheadBenchmarkConfig.shared.disableTranscriptPreviewBatching,
            captureConsoleOutput: captureConsoleOutput,
            progressSink: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.setAnalyzeProgress(Self.mapTranscriptProgress(progress, in: progressRange), fileName: fileName)
                }
            },
            segmentSink: { [weak self] segments in
                Task { @MainActor [weak self] in
                    self?.enqueueGeneratedTranscriptPreviewSegments(segments)
                }
            },
            consoleSink: { [weak self] chunk in
                Task { @MainActor [weak self] in
                    self?.appendActivityConsoleChunk(chunk)
                }
            }
        )
        transcriptGenerationRelay = relay

        let result = await Task.detached(priority: .userInitiated) {
            transcribeAudioWithWhisper(
                file: file,
                shouldCancel: shouldCancel,
                progressHandler: { progress in
                    relay.enqueueProgress(progress)
                },
                onConsoleOutput: { line, source in
                    relay.enqueueConsole(line: line, source: source)
                },
                onTranscriptSegment: { segment in
                    relay.enqueueSegment(segment)
                }
            )
        }.value

        relay.flushNow()
        return result
    }

    func cacheGeneratedTranscript(_ transcript: [TranscriptSegment]) {
        transcriptSegments = transcript
        hasCachedTranscript = true
        if transcript.isEmpty {
            transcriptStatusText = "Transcript generated (no speech detected)."
        } else {
            transcriptStatusText = "Transcript generated (\(transcript.count) segment(s))."
        }
        analyzeStatusText = transcriptStatusText
        uiMessage = transcriptStatusText
    }

    func clearTranscriptGenerationState(statusText: String, analyzeStatus: String? = nil) {
        transcriptSegments = []
        hasCachedTranscript = false
        transcriptStatusText = statusText
        analyzeStatusText = analyzeStatus ?? statusText
        uiMessage = statusText
    }

    private func enqueueGeneratedTranscriptPreviewSegments(_ segments: [TranscriptSegment]) {
        guard isGeneratingTranscript else { return }
        if PlayheadBenchmarkConfig.shared.disableTranscriptPreviewBatching {
            if !segments.isEmpty {
                PlayheadDiagnostics.shared.noteModelWrite("transcript_preview_segment_immediate")
                applyTranscriptPreviewSegments(segments)
            }
            return
        }
        guard !segments.isEmpty else { return }
        pendingTranscriptPreviewSegments.append(contentsOf: segments)
        PlayheadDiagnostics.shared.noteModelWrite("transcript_preview_segment_enqueued")
        scheduleTranscriptPreviewFlush(immediate: false)
    }

    private func scheduleTranscriptPreviewFlush(immediate: Bool) {
        guard isGeneratingTranscript else { return }
        if immediate {
            transcriptPreviewFlushTask?.cancel()
            transcriptPreviewFlushTask = nil
        }

        if isInteractiveTimelineScrubbing && !immediate {
            return
        }

        guard transcriptPreviewFlushTask == nil else { return }
        let delaySeconds: Double = immediate ? 0 : 0.12
        transcriptPreviewFlushTask = Task { @MainActor [weak self] in
            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.flushPendingTranscriptPreviewSegments()
        }
    }

    private func flushPendingTranscriptPreviewSegments() {
        transcriptPreviewFlushTask = nil
        guard isGeneratingTranscript else {
            pendingTranscriptPreviewSegments.removeAll(keepingCapacity: false)
            return
        }

        let pending = pendingTranscriptPreviewSegments
        pendingTranscriptPreviewSegments.removeAll(keepingCapacity: true)
        applyTranscriptPreviewSegments(pending)
        PlayheadDiagnostics.shared.noteModelWrite("transcript_preview_flush")
    }

    private func applyTranscriptPreviewSegments(_ pending: [TranscriptSegment]) {
        guard !pending.isEmpty else { return }

        var mergedSegments = transcriptSegments
        var knownKeys = Set(mergedSegments.map { Self.transcriptPreviewIdentity(for: $0) })
        var appendedCount = 0

        for segment in pending {
            let key = Self.transcriptPreviewIdentity(for: segment)
            guard knownKeys.insert(key).inserted else { continue }
            mergedSegments.append(segment)
            appendedCount += 1
        }

        guard appendedCount > 0 else { return }

        mergedSegments.sort { lhs, rhs in
            if abs(lhs.start - rhs.start) > 0.0001 {
                return lhs.start < rhs.start
            }
            return lhs.end < rhs.end
        }

        transcriptSegments = mergedSegments
        let count = mergedSegments.count
        let noun = count == 1 ? "segment" : "segments"
        transcriptStatusText = "Generating transcript… (\(count) \(noun))"
        analyzeStatusText = transcriptStatusText
        uiMessage = transcriptStatusText
    }

    private static func transcriptPreviewIdentity(for segment: TranscriptSegment) -> String {
        let startMillis = Int((segment.start * 1000.0).rounded())
        let endMillis = Int((segment.end * 1000.0).rounded())
        return "\(startMillis)|\(endMillis)|\(segment.text)"
    }

    private static func syntheticBenchmarkTranscriptSegment(index: Int) -> TranscriptSegment {
        let phrases = [
            "Synthetic transcript preview line for scrubbing benchmark load.",
            "This segment exists to exercise transcript table churn during drag.",
            "Benchmark transcript updates should stress publish frequency, not input handling.",
            "Native scrubbing should stay responsive while preview text streams in."
        ]
        let start = Double(index) * 1.35
        let end = start + 1.1
        let phrase = phrases[index % phrases.count]
        return TranscriptSegment(
            start: start,
            end: end,
            text: "\(phrase) Segment \(index + 1)."
        )
    }

    private static func mapTranscriptProgress(_ progress: Double, in range: ClosedRange<Double>) -> Double {
        let clamped = min(1.0, max(0.0, progress))
        return range.lowerBound + ((range.upperBound - range.lowerBound) * clamped)
    }

    private func transcriptPlainText() -> String {
        TranscriptUtilities.plainText(from: transcriptSegments)
    }

    private func srtTimestamp(_ seconds: Double) -> String {
        TranscriptUtilities.srtTimestamp(seconds)
    }

    private func transcriptSRT() -> String {
        TranscriptUtilities.srt(from: transcriptSegments)
    }

    func exportTranscriptFromInspect() {
        guard let sourceURL else { return }
        guard !transcriptSegments.isEmpty else { return }

        let (panel, formatPopup) = TranscriptUtilities.makeExportPanel(
            defaultName: sourceURL.deletingPathExtension().lastPathComponent + "_transcript.txt"
        )

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let selectedExtension = formatPopup.indexOfSelectedItem == 1 ? "srt" : "txt"
        let resolvedDestination: URL = {
            if destination.pathExtension.lowercased() == selectedExtension {
                return destination
            }
            return destination.deletingPathExtension().appendingPathExtension(selectedExtension)
        }()

        let ext = selectedExtension
        let content: String
        switch ext {
        case "srt":
            content = transcriptSRT()
        case "txt", "":
            content = transcriptPlainText()
        default:
            uiMessage = "Transcript export failed: Unsupported format \(ext)"
            lastActivityState = .failed
            notifyCompletion("Transcript Export Failed", message: uiMessage)
            return
        }

        do {
            try content.write(to: resolvedDestination, atomically: true, encoding: .utf8)
            outputURL = resolvedDestination
            uiMessage = "Transcript exported to \(resolvedDestination.lastPathComponent)"
            lastActivityState = .success
            if let soundName = completionSound.soundName,
               let sound = NSSound(named: soundName) {
                sound.play()
            }
            notifyCompletion("Transcript Export Complete", message: uiMessage)
        } catch {
            uiMessage = "Transcript export failed: \(error.localizedDescription)"
            lastActivityState = .failed
            notifyCompletion("Transcript Export Failed", message: uiMessage)
        }
    }
}
