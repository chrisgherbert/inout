import AppKit
import Foundation
import InOutCore

@MainActor
extension WorkspaceViewModel {
    func startAnalysis(queueJobID: UUID? = nil) {
        if queueJobID == nil && (isAnalyzing || isExporting || isGeneratingTranscript) {
            enqueueCurrentAnalysis()
            return
        }
        guard canRequestAnalyze, let url = sourceURL else {
            completeQueuedJobIfNeeded(queueJobID, status: .failed, message: "Unable to start analysis.")
            return
        }

        let requestedBlack = effectiveAnalyzeBlackFrames
        let requestedBadEdits = effectiveAnalyzeBadEdits
        let requestedSilence = effectiveAnalyzeAudioSilence
        let requestedProfanity = effectiveAnalyzeProfanity
        let requestedProfanityWordsSnapshot = normalizedProfanityWordsStorageString(profanityWordsText)
        let requestedProfanityWordsSet = selectedProfanityWords
        let cachedTranscript = hasCachedTranscript ? transcriptSegments : nil
        let needsFreshTranscript = requestedProfanity && cachedTranscript == nil

        let previous = analysis
        let hasCompletedPrevious: Bool
        if let previous {
            if case .done = previous.status {
                hasCompletedPrevious = true
            } else {
                hasCompletedPrevious = false
            }
        } else {
            hasCompletedPrevious = false
        }

        let hasCachedBlack = hasCompletedPrevious && (previous?.includedBlackDetection == true)
        let hasCachedBadEdits = hasCompletedPrevious && (previous?.includedBadEditDetection == true)
        let hasCachedSilence = hasCompletedPrevious
            && (previous?.includedSilenceDetection == true)
            && abs((previous?.silenceMinDurationSeconds ?? 0) - silenceMinDurationSeconds) < 0.0001
        let hasCachedProfanity = hasCompletedPrevious
            && (previous?.includedProfanityDetection == true)
            && (previous?.profanityWordsSnapshot == requestedProfanityWordsSnapshot)

        let runBlack = requestedBlack && !hasCachedBlack
        let runBadEdits = requestedBadEdits && !hasCachedBadEdits
        let runSilence = requestedSilence && !hasCachedSilence
        let runProfanity = requestedProfanity && !hasCachedProfanity

        let cachedBlackSegments: [Segment] = requestedBlack && hasCachedBlack ? (previous?.segments ?? []) : []
        let cachedBadEditIssues: [BadEditIssue] = requestedBadEdits && hasCachedBadEdits ? (previous?.badEditIssues ?? []) : []
        let cachedSilentSegments: [Segment] = requestedSilence && hasCachedSilence ? (previous?.silentSegments ?? []) : []
        let cachedProfanityHits: [ProfanityHit] = requestedProfanity && hasCachedProfanity ? (previous?.profanityHits ?? []) : []

        if !runBlack && !runBadEdits && !runSilence && !runProfanity {
            analysis = FileAnalysis(
                fileURL: url,
                segments: cachedBlackSegments,
                silentSegments: cachedSilentSegments,
                profanityHits: cachedProfanityHits,
                badEditIssues: cachedBadEditIssues,
                includedBlackDetection: requestedBlack,
                includedSilenceDetection: requestedSilence,
                includedProfanityDetection: requestedProfanity,
                includedBadEditDetection: requestedBadEdits,
                profanityWordsSnapshot: requestedProfanityWordsSnapshot,
                silenceMinDurationSeconds: silenceMinDurationSeconds,
                mediaDuration: sourceInfo?.durationSeconds ?? previous?.mediaDuration,
                progress: 1.0,
                status: .done
            )
            analyzeProgress = 0
            analyzeStatusText = "Using cached analysis results."
            uiMessage = analysis?.summary ?? "Using cached analysis results."
            lastActivityState = .success
            completeQueuedJobIfNeeded(queueJobID, status: .completed, message: uiMessage)
            return
        }

        if queueJobID == nil {
            _ = beginDirectJobTracking(
                fileName: url.lastPathComponent,
                summary: analysisJobTitle(
                    black: requestedBlack,
                    badEdits: requestedBadEdits,
                    silence: requestedSilence,
                    profanity: requestedProfanity
                ),
                subtitle: analysisJobSubtitle(
                    black: requestedBlack,
                    badEdits: requestedBadEdits,
                    silence: requestedSilence,
                    profanity: requestedProfanity
                )
            )
        }

        isAnalyzing = true
        lastActivityState = .running
        wasCancelled = false
        analyzeProgress = 0
        clearActivityConsole()
        appendActivityConsole("Analysis started", source: "analysis")
        analyzePhaseText = "Preparing analysis"
        scheduleAnalyzeFeedbackUpdate(progress: 0, fileName: url.lastPathComponent, immediate: true)
        cancelFlag.reset()

        let knownDuration = sourceInfo?.durationSeconds

        if var existing = analysis {
            existing.status = .running
            existing.progress = 0
            existing.segments = runBlack ? [] : cachedBlackSegments
            existing.badEditIssues = runBadEdits ? [] : cachedBadEditIssues
            existing.silentSegments = runSilence ? [] : cachedSilentSegments
            existing.profanityHits = runProfanity ? [] : cachedProfanityHits
            existing.includedBlackDetection = requestedBlack
            existing.includedBadEditDetection = requestedBadEdits
            existing.includedSilenceDetection = requestedSilence
            existing.includedProfanityDetection = requestedProfanity
            existing.profanityWordsSnapshot = requestedProfanityWordsSnapshot
            existing.silenceMinDurationSeconds = silenceMinDurationSeconds
            existing.mediaDuration = knownDuration
            analysis = existing
        } else {
            analysis = FileAnalysis(
                fileURL: url,
                segments: runBlack ? [] : cachedBlackSegments,
                silentSegments: runSilence ? [] : cachedSilentSegments,
                profanityHits: runProfanity ? [] : cachedProfanityHits,
                badEditIssues: runBadEdits ? [] : cachedBadEditIssues,
                includedBlackDetection: requestedBlack,
                includedSilenceDetection: requestedSilence,
                includedProfanityDetection: requestedProfanity,
                includedBadEditDetection: requestedBadEdits,
                profanityWordsSnapshot: requestedProfanityWordsSnapshot,
                silenceMinDurationSeconds: silenceMinDurationSeconds,
                mediaDuration: knownDuration,
                status: .running
            )
        }

        analyzeTask = Task { [weak self] in
            guard let self else { return }
            let flag = cancelFlag
            let detectBlack = runBlack
            let detectBadEdits = runBadEdits
            let detectSilence = runSilence
            let detectProfanity = runProfanity
            let silenceMinDuration = self.silenceMinDurationSeconds
            let profanityWords = requestedProfanityWordsSet
            let captureConsoleOutput = self.showActivityConsole
            let fileName = url.lastPathComponent
            var transcriptForAnalysis = cachedTranscript

            if needsFreshTranscript {
                let transcriptProgressRange: ClosedRange<Double> = (detectBlack || detectBadEdits || detectSilence) ? (0.0...0.45) : (0.0...0.92)
                let analysisProgressRange: ClosedRange<Double> = (detectBlack || detectBadEdits || detectSilence) ? (0.45...1.0) : (0.92...1.0)

                self.prepareTranscriptGenerationState(
                    fileName: fileName,
                    beginDirectJobTrackingForTranscript: false,
                    clearConsole: false,
                    resetProgress: false
                )

                let transcriptResult = await self.runSharedTranscriptGeneration(
                    file: url,
                    fileName: fileName,
                    progressRange: transcriptProgressRange,
                    captureConsoleOutput: captureConsoleOutput,
                    shouldCancel: {
                        flag.isCancelled()
                    }
                )

                self.resetTranscriptPreviewPipeline()
                self.isGeneratingTranscript = false

                switch transcriptResult {
                case .success(let transcript):
                    transcriptForAnalysis = transcript
                    self.cacheGeneratedTranscript(transcript)
                case .failure(.cancelled):
                    self.clearTranscriptGenerationState(statusText: "Transcript generation stopped.", analyzeStatus: "Analysis stopped")
                    self.applyAnalysisResult(
                        .failure(.cancelled),
                        includedBlack: requestedBlack,
                        includedBadEdits: requestedBadEdits,
                        includedSilence: requestedSilence,
                        includedProfanity: requestedProfanity,
                        ranBlack: runBlack,
                        ranBadEdits: runBadEdits,
                        ranSilence: runSilence,
                        ranProfanity: runProfanity,
                        cachedBlackSegments: cachedBlackSegments,
                        cachedBadEditIssues: cachedBadEditIssues,
                        cachedSilentSegments: cachedSilentSegments,
                        cachedProfanityHits: cachedProfanityHits,
                        profanityWordsSnapshot: requestedProfanityWordsSnapshot
                    )
                    self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.uiMessage)
                    return
                case .failure(.failed(let reason)):
                    self.clearTranscriptGenerationState(statusText: "Transcript failed: \(reason)", analyzeStatus: "Analysis failed")
                    self.applyAnalysisResult(
                        .failure(.failed(reason)),
                        includedBlack: requestedBlack,
                        includedBadEdits: requestedBadEdits,
                        includedSilence: requestedSilence,
                        includedProfanity: requestedProfanity,
                        ranBlack: runBlack,
                        ranBadEdits: runBadEdits,
                        ranSilence: runSilence,
                        ranProfanity: runProfanity,
                        cachedBlackSegments: cachedBlackSegments,
                        cachedBadEditIssues: cachedBadEditIssues,
                        cachedSilentSegments: cachedSilentSegments,
                        cachedProfanityHits: cachedProfanityHits,
                        profanityWordsSnapshot: requestedProfanityWordsSnapshot
                    )
                    self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.uiMessage)
                    return
                }

                let result = await Task.detached(priority: .userInitiated) {
                    runDetection(
                        file: url,
                        detectBlackFrames: detectBlack,
                        detectBadEdits: detectBadEdits,
                        detectAudioSilence: detectSilence,
                        detectProfanity: detectProfanity,
                        profanityWords: profanityWords,
                        cachedTranscriptSegments: transcriptForAnalysis,
                        silenceMinDuration: silenceMinDuration,
                        onStatusUpdate: { status in
                            Task { @MainActor [weak self] in
                                self?.setAnalyzePhase(status, fileName: fileName)
                            }
                        },
                        onBlackSegmentDetected: { segment in
                            Task { @MainActor [weak self] in
                                self?.appendDetectedBlackSegment(segment)
                            }
                        },
                        onBadEditDetected: { issue in
                            Task { @MainActor [weak self] in
                                self?.appendDetectedBadEditIssue(issue)
                            }
                        },
                        onSilentSegmentDetected: { segment in
                            Task { @MainActor [weak self] in
                                self?.appendDetectedSilentSegment(segment)
                            }
                        },
                        onProfanityDetected: { hit in
                            Task { @MainActor [weak self] in
                                self?.appendDetectedProfanityHit(hit)
                            }
                        },
                        onConsoleOutput: { line, source in
                            guard captureConsoleOutput else { return }
                            Task { @MainActor [weak self] in
                                self?.appendActivityConsole(line, source: source)
                            }
                        }
                    ) { progress in
                        Task { @MainActor [weak self] in
                            let mapped = analysisProgressRange.lowerBound
                                + ((analysisProgressRange.upperBound - analysisProgressRange.lowerBound) * min(1.0, max(0.0, progress)))
                            self?.setAnalyzeProgress(mapped, fileName: fileName)
                        }
                    } shouldCancel: {
                        flag.isCancelled()
                    }
                }.value

                self.applyAnalysisResult(
                    result,
                    includedBlack: requestedBlack,
                    includedBadEdits: requestedBadEdits,
                    includedSilence: requestedSilence,
                    includedProfanity: requestedProfanity,
                    ranBlack: runBlack,
                    ranBadEdits: runBadEdits,
                    ranSilence: runSilence,
                    ranProfanity: runProfanity,
                    cachedBlackSegments: cachedBlackSegments,
                    cachedBadEditIssues: cachedBadEditIssues,
                    cachedSilentSegments: cachedSilentSegments,
                    cachedProfanityHits: cachedProfanityHits,
                    profanityWordsSnapshot: requestedProfanityWordsSnapshot
                )
                switch result {
                case .success:
                    self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.uiMessage)
                case .failure(.cancelled):
                    self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.uiMessage)
                case .failure:
                    self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.uiMessage)
                }
                return
            }

            let result = await Task.detached(priority: .userInitiated) {
                runDetection(
                    file: url,
                    detectBlackFrames: detectBlack,
                    detectBadEdits: detectBadEdits,
                    detectAudioSilence: detectSilence,
                    detectProfanity: detectProfanity,
                    profanityWords: profanityWords,
                    cachedTranscriptSegments: transcriptForAnalysis,
                    silenceMinDuration: silenceMinDuration,
                    onStatusUpdate: { status in
                        Task { @MainActor [weak self] in
                            self?.setAnalyzePhase(status, fileName: fileName)
                        }
                    },
                    onBlackSegmentDetected: { segment in
                        Task { @MainActor [weak self] in
                            self?.appendDetectedBlackSegment(segment)
                        }
                    },
                    onBadEditDetected: { issue in
                        Task { @MainActor [weak self] in
                            self?.appendDetectedBadEditIssue(issue)
                        }
                    },
                    onSilentSegmentDetected: { segment in
                        Task { @MainActor [weak self] in
                            self?.appendDetectedSilentSegment(segment)
                        }
                    },
                    onProfanityDetected: { hit in
                        Task { @MainActor [weak self] in
                            self?.appendDetectedProfanityHit(hit)
                        }
                    },
                    onConsoleOutput: { line, source in
                        guard captureConsoleOutput else { return }
                        Task { @MainActor [weak self] in
                            self?.appendActivityConsole(line, source: source)
                        }
                    }
                ) { progress in
                    Task { @MainActor [weak self] in
                        self?.setAnalyzeProgress(progress, fileName: fileName)
                    }
                } shouldCancel: {
                    flag.isCancelled()
                }
            }.value

            self.applyAnalysisResult(
                result,
                includedBlack: requestedBlack,
                includedBadEdits: requestedBadEdits,
                includedSilence: requestedSilence,
                includedProfanity: requestedProfanity,
                ranBlack: runBlack,
                ranBadEdits: runBadEdits,
                ranSilence: runSilence,
                ranProfanity: runProfanity,
                cachedBlackSegments: cachedBlackSegments,
                cachedBadEditIssues: cachedBadEditIssues,
                cachedSilentSegments: cachedSilentSegments,
                cachedProfanityHits: cachedProfanityHits,
                profanityWordsSnapshot: requestedProfanityWordsSnapshot
            )
            switch result {
            case .success:
                self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.uiMessage)
            case .failure(.cancelled):
                self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.uiMessage)
            case .failure:
                self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.uiMessage)
            }
        }
    }

    func stopAnalysis() {
        guard isAnalyzing else { return }
        cancelFlag.cancel()
        analyzeTask?.cancel()
    }

    func setAnalyzeProgress(_ progress: Double, fileName: String) {
        let clamped = min(1, max(0, progress))
        scheduleAnalyzeFeedbackUpdate(progress: clamped, fileName: fileName)
    }

    func setAnalyzePhase(_ phase: String, fileName: String) {
        analyzePhaseText = phase
        scheduleAnalyzeFeedbackUpdate(fileName: fileName, immediate: true)
    }

    func appendDetectedBlackSegment(_ segment: Segment) {
        guard var current = analysis else { return }
        guard case .running = current.status else { return }
        if !containsSegment(current.segments, segment) {
            current.segments.append(segment)
            analysis = current
        }
    }

    func appendDetectedBadEditIssue(_ issue: BadEditIssue) {
        guard var current = analysis else { return }
        guard case .running = current.status else { return }
        if let index = current.badEditIssues.firstIndex(where: { $0.id == issue.id }) {
            current.badEditIssues[index] = issue
            analysis = current
            return
        }
        if !current.badEditIssues.contains(where: {
            $0.kind == issue.kind && abs($0.start - issue.start) < 0.001
        }) {
            current.badEditIssues.append(issue)
            analysis = current
        }
    }

    func appendDetectedSilentSegment(_ segment: Segment) {
        guard var current = analysis else { return }
        guard case .running = current.status else { return }
        if !containsSegment(current.silentSegments, segment) {
            current.silentSegments.append(segment)
            analysis = current
        }
    }

    func appendDetectedProfanityHit(_ hit: ProfanityHit) {
        guard var current = analysis else { return }
        guard case .running = current.status else { return }
        if !current.profanityHits.contains(where: {
            abs($0.start - hit.start) < 0.001 &&
            abs($0.end - hit.end) < 0.001 &&
            $0.word == hit.word
        }) {
            current.profanityHits.append(hit)
            analysis = current
        }
    }

    func containsSegment(_ list: [Segment], _ candidate: Segment) -> Bool {
        list.contains {
            abs($0.start - candidate.start) < 0.001 &&
            abs($0.end - candidate.end) < 0.001
        }
    }

    func applyAnalysisResult(
        _ result: Result<DetectionOutput, DetectionError>,
        includedBlack: Bool,
        includedBadEdits: Bool,
        includedSilence: Bool,
        includedProfanity: Bool,
        ranBlack: Bool,
        ranBadEdits: Bool,
        ranSilence: Bool,
        ranProfanity: Bool,
        cachedBlackSegments: [Segment],
        cachedBadEditIssues: [BadEditIssue],
        cachedSilentSegments: [Segment],
        cachedProfanityHits: [ProfanityHit],
        profanityWordsSnapshot: String
    ) {
        isAnalyzing = false
        isGeneratingTranscript = false
        analyzeTask = nil
        cancelAnalyzeFeedbackUpdates()
        analyzeProgress = 0
        analyzePhaseText = "Preparing analysis"

        guard var current = analysis else { return }
        switch result {
        case .success(let output):
            current.segments = ranBlack ? output.segments : cachedBlackSegments
            current.badEditIssues = ranBadEdits ? output.badEditIssues : cachedBadEditIssues
            current.silentSegments = ranSilence ? output.silentSegments : cachedSilentSegments
            current.profanityHits = ranProfanity ? output.profanityHits : cachedProfanityHits
            current.includedBlackDetection = includedBlack
            current.includedBadEditDetection = includedBadEdits
            current.includedSilenceDetection = includedSilence
            current.includedProfanityDetection = includedProfanity
            current.profanityWordsSnapshot = profanityWordsSnapshot
            current.mediaDuration = output.mediaDuration
            current.progress = 1
            current.status = .done
            analysis = current
            if includedProfanity, let transcript = output.transcriptSegments {
                cacheGeneratedTranscript(transcript)
            }
            if current.segments.isEmpty && current.badEditIssues.isEmpty && current.silentSegments.isEmpty && current.profanityHits.isEmpty {
                var noneParts: [String] = []
                if includedBlack { noneParts.append("black segments") }
                if includedBadEdits { noneParts.append("possible bad edits") }
                if includedSilence { noneParts.append("silent gaps") }
                if includedProfanity { noneParts.append("profanity") }
                uiMessage = noneParts.isEmpty ? "No analysis type enabled." : "No \(noneParts.joined(separator: ", ")) found."
            } else {
                var parts: [String] = []
                if includedBlack {
                    if current.segments.isEmpty {
                        parts.append("No black segments")
                    } else {
                        parts.append("\(current.segments.count) black segment(s)")
                    }
                }
                if includedBadEdits {
                    if current.badEditIssues.isEmpty {
                        parts.append("No possible bad edits")
                    } else {
                        parts.append("\(current.badEditIssues.count) possible bad edit(s)")
                    }
                }
                if includedSilence {
                    if current.silentSegments.isEmpty {
                        parts.append("No silent gaps")
                    } else {
                        parts.append("\(current.silentSegments.count) silent gap(s)")
                    }
                }
                if includedProfanity {
                    if current.profanityHits.isEmpty {
                        parts.append("No profanity")
                    } else {
                        parts.append("\(current.profanityHits.count) profanity hit(s)")
                    }
                }
                uiMessage = "Detected: " + parts.joined(separator: ", ")
            }
            analyzeStatusText = uiMessage
            lastActivityState = .success
            notifyCompletion("Media Analysis Complete", message: uiMessage)
        case .failure(.cancelled):
            current.status = .failed("Stopped")
            analysis = current
            wasCancelled = true
            analyzeStatusText = "Analysis stopped"
            uiMessage = "Analysis stopped"
            lastActivityState = .cancelled
            notifyCompletion("Media Analysis Stopped", message: uiMessage, outcome: .cancelled)
        case .failure(.failed(let reason)):
            current.status = .failed(reason)
            analysis = current
            analyzeStatusText = "Analysis failed"
            uiMessage = "Analysis failed: \(reason)"
            lastActivityState = .failed
            notifyCompletion("Media Analysis Failed", message: uiMessage, outcome: .failed)
        }
    }

    func applyTranscriptGenerationResult(
        _ result: Result<[TranscriptSegment], DetectionError>
    ) {
        resetTranscriptPreviewPipeline()
        isGeneratingTranscript = false
        isAnalyzing = false
        analyzeTask = nil
        cancelAnalyzeFeedbackUpdates()
        analyzeProgress = 0
        analyzePhaseText = "Preparing analysis"

        switch result {
        case .success(let transcript):
            cacheGeneratedTranscript(transcript)
            lastActivityState = .success
            notifyCompletion("Transcript Complete", message: transcriptStatusText)
            completeQueuedJobIfNeeded(nil, status: .completed, message: transcriptStatusText)
        case .failure(.cancelled):
            clearTranscriptGenerationState(statusText: "Transcript generation stopped.")
            lastActivityState = .cancelled
            notifyCompletion("Transcript Stopped", message: transcriptStatusText, outcome: .cancelled)
            completeQueuedJobIfNeeded(nil, status: .cancelled, message: transcriptStatusText)
        case .failure(.failed(let reason)):
            clearTranscriptGenerationState(
                statusText: "Transcript failed: \(reason)",
                analyzeStatus: "Transcript generation failed"
            )
            lastActivityState = .failed
            notifyCompletion("Transcript Failed", message: transcriptStatusText, outcome: .failed)
            completeQueuedJobIfNeeded(nil, status: .failed, message: transcriptStatusText)
        }
    }
}
