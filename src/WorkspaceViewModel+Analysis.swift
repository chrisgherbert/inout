import AppKit
import Foundation

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
        let requestedSilence = effectiveAnalyzeAudioSilence
        let requestedProfanity = effectiveAnalyzeProfanity
        let requestedProfanityWordsSnapshot = normalizedProfanityWordsStorageString(profanityWordsText)
        let requestedProfanityWordsSet = selectedProfanityWords
        let cachedTranscript = hasCachedTranscript ? transcriptSegments : nil

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
        let hasCachedSilence = hasCompletedPrevious
            && (previous?.includedSilenceDetection == true)
            && abs((previous?.silenceMinDurationSeconds ?? 0) - silenceMinDurationSeconds) < 0.0001
        let hasCachedProfanity = hasCompletedPrevious
            && (previous?.includedProfanityDetection == true)
            && (previous?.profanityWordsSnapshot == requestedProfanityWordsSnapshot)

        let runBlack = requestedBlack && !hasCachedBlack
        let runSilence = requestedSilence && !hasCachedSilence
        let runProfanity = requestedProfanity && !hasCachedProfanity

        let cachedBlackSegments: [Segment] = requestedBlack && hasCachedBlack ? (previous?.segments ?? []) : []
        let cachedSilentSegments: [Segment] = requestedSilence && hasCachedSilence ? (previous?.silentSegments ?? []) : []
        let cachedProfanityHits: [ProfanityHit] = requestedProfanity && hasCachedProfanity ? (previous?.profanityHits ?? []) : []

        if !runBlack && !runSilence && !runProfanity {
            analysis = FileAnalysis(
                fileURL: url,
                segments: cachedBlackSegments,
                silentSegments: cachedSilentSegments,
                profanityHits: cachedProfanityHits,
                includedBlackDetection: requestedBlack,
                includedSilenceDetection: requestedSilence,
                includedProfanityDetection: requestedProfanity,
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
                    silence: requestedSilence,
                    profanity: requestedProfanity
                ),
                subtitle: analysisJobSubtitle(
                    black: requestedBlack,
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
        updateAnalyzeStatusText(fileName: url.lastPathComponent, progress: 0)
        cancelFlag.reset()

        let knownDuration = sourceInfo?.durationSeconds

        if var existing = analysis {
            existing.status = .running
            existing.progress = 0
            existing.segments = runBlack ? [] : cachedBlackSegments
            existing.silentSegments = runSilence ? [] : cachedSilentSegments
            existing.profanityHits = runProfanity ? [] : cachedProfanityHits
            existing.includedBlackDetection = requestedBlack
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
                includedBlackDetection: requestedBlack,
                includedSilenceDetection: requestedSilence,
                includedProfanityDetection: requestedProfanity,
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
            let detectSilence = runSilence
            let detectProfanity = runProfanity
            let silenceMinDuration = self.silenceMinDurationSeconds
            let profanityWords = requestedProfanityWordsSet
            let captureConsoleOutput = self.showActivityConsole
            let result = await Task.detached(priority: .userInitiated) {
                runDetection(
                    file: url,
                    detectBlackFrames: detectBlack,
                    detectAudioSilence: detectSilence,
                    detectProfanity: detectProfanity,
                    profanityWords: profanityWords,
                    cachedTranscriptSegments: cachedTranscript,
                    silenceMinDuration: silenceMinDuration,
                    onStatusUpdate: { status in
                        Task { @MainActor [weak self] in
                            self?.setAnalyzePhase(status, fileName: url.lastPathComponent)
                        }
                    },
                    onBlackSegmentDetected: { segment in
                        Task { @MainActor [weak self] in
                            self?.appendDetectedBlackSegment(segment)
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
                        self?.setAnalyzeProgress(progress, fileName: url.lastPathComponent)
                    }
                } shouldCancel: {
                    flag.isCancelled()
                }
            }.value

            self.applyAnalysisResult(
                result,
                includedBlack: requestedBlack,
                includedSilence: requestedSilence,
                includedProfanity: requestedProfanity,
                ranBlack: runBlack,
                ranSilence: runSilence,
                ranProfanity: runProfanity,
                cachedBlackSegments: cachedBlackSegments,
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
        analyzeProgress = clamped
        updateAnalyzeStatusText(fileName: fileName, progress: clamped)
        if var current = analysis {
            current.progress = clamped
            analysis = current
        }
    }

    func setAnalyzePhase(_ phase: String, fileName: String) {
        analyzePhaseText = phase
        updateAnalyzeStatusText(fileName: fileName, progress: analyzeProgress)
    }

    func updateAnalyzeStatusText(fileName: String, progress: Double) {
        let percent = Int((min(1, max(0, progress)) * 100).rounded())
        analyzeStatusText = "\(analyzePhaseText)… \(percent)%"
    }

    func appendDetectedBlackSegment(_ segment: Segment) {
        guard var current = analysis else { return }
        guard case .running = current.status else { return }
        if !containsSegment(current.segments, segment) {
            current.segments.append(segment)
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
        includedSilence: Bool,
        includedProfanity: Bool,
        ranBlack: Bool,
        ranSilence: Bool,
        ranProfanity: Bool,
        cachedBlackSegments: [Segment],
        cachedSilentSegments: [Segment],
        cachedProfanityHits: [ProfanityHit],
        profanityWordsSnapshot: String
    ) {
        isAnalyzing = false
        isGeneratingTranscript = false
        analyzeTask = nil
        analyzeProgress = 0
        analyzePhaseText = "Preparing analysis"

        guard var current = analysis else { return }
        switch result {
        case .success(let output):
            current.segments = ranBlack ? output.segments : cachedBlackSegments
            current.silentSegments = ranSilence ? output.silentSegments : cachedSilentSegments
            current.profanityHits = ranProfanity ? output.profanityHits : cachedProfanityHits
            current.includedBlackDetection = includedBlack
            current.includedSilenceDetection = includedSilence
            current.includedProfanityDetection = includedProfanity
            current.profanityWordsSnapshot = profanityWordsSnapshot
            current.mediaDuration = output.mediaDuration
            current.progress = 1
            current.status = .done
            analysis = current
            if includedProfanity, let transcript = output.transcriptSegments {
                transcriptSegments = transcript
                hasCachedTranscript = true
                transcriptStatusText = transcript.isEmpty ? "Transcript generated (no speech detected)." : "Transcript generated (\(transcript.count) segment(s))."
            }
            if current.segments.isEmpty && current.silentSegments.isEmpty && current.profanityHits.isEmpty {
                var noneParts: [String] = []
                if includedBlack { noneParts.append("black segments") }
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
            if let soundName = completionSound.soundName,
               let sound = NSSound(named: soundName) {
                sound.play()
            }
            notifyCompletion("Black Frame Analysis Complete", message: uiMessage)
        case .failure(.cancelled):
            current.status = .failed("Stopped")
            analysis = current
            wasCancelled = true
            analyzeStatusText = "Analysis stopped"
            uiMessage = "Analysis stopped"
            lastActivityState = .cancelled
            notifyCompletion("Black Frame Analysis Stopped", message: uiMessage)
        case .failure(.failed(let reason)):
            current.status = .failed(reason)
            analysis = current
            analyzeStatusText = "Analysis failed"
            uiMessage = "Analysis failed: \(reason)"
            lastActivityState = .failed
            notifyCompletion("Black Frame Analysis Failed", message: uiMessage)
        }
    }

    func applyTranscriptGenerationResult(
        _ result: Result<[TranscriptSegment], DetectionError>
    ) {
        isGeneratingTranscript = false
        isAnalyzing = false
        analyzeTask = nil
        analyzeProgress = 0
        analyzePhaseText = "Preparing analysis"

        switch result {
        case .success(let transcript):
            transcriptSegments = transcript
            hasCachedTranscript = true
            if transcript.isEmpty {
                transcriptStatusText = "Transcript generated (no speech detected)."
            } else {
                transcriptStatusText = "Transcript generated (\(transcript.count) segment(s))."
            }
            analyzeStatusText = transcriptStatusText
            uiMessage = transcriptStatusText
            lastActivityState = .success
            if let soundName = completionSound.soundName,
               let sound = NSSound(named: soundName) {
                sound.play()
            }
            notifyCompletion("Transcript Complete", message: transcriptStatusText)
            completeQueuedJobIfNeeded(nil, status: .completed, message: transcriptStatusText)
        case .failure(.cancelled):
            transcriptSegments = []
            hasCachedTranscript = false
            transcriptStatusText = "Transcript generation stopped."
            analyzeStatusText = transcriptStatusText
            uiMessage = transcriptStatusText
            lastActivityState = .cancelled
            notifyCompletion("Transcript Stopped", message: transcriptStatusText)
            completeQueuedJobIfNeeded(nil, status: .cancelled, message: transcriptStatusText)
        case .failure(.failed(let reason)):
            transcriptSegments = []
            hasCachedTranscript = false
            transcriptStatusText = "Transcript failed: \(reason)"
            analyzeStatusText = "Transcript generation failed"
            uiMessage = transcriptStatusText
            lastActivityState = .failed
            notifyCompletion("Transcript Failed", message: transcriptStatusText)
            completeQueuedJobIfNeeded(nil, status: .failed, message: transcriptStatusText)
        }
    }
}
