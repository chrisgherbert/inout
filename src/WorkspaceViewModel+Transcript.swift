import Foundation
import AppKit

extension WorkspaceViewModel {
    func generateTranscriptFromInspect() {
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

        _ = beginDirectJobTracking(
            fileName: url.lastPathComponent,
            summary: "Generate Transcript",
            subtitle: "Whisper"
        )

        isGeneratingTranscript = true
        isAnalyzing = true
        lastActivityState = .running
        wasCancelled = false
        transcriptSegments = []
        hasCachedTranscript = false
        analyzeProgress = 0
        clearActivityConsole()
        appendActivityConsole("Transcript generation started", source: "analysis")
        analyzePhaseText = "Transcribing audio"
        updateAnalyzeStatusText(fileName: url.lastPathComponent, progress: 0)
        transcriptStatusText = "Generating transcript…"
        uiMessage = transcriptStatusText
        cancelFlag.reset()

        analyzeTask = Task { [weak self] in
            guard let self else { return }
            let flag = cancelFlag
            let result = await Task.detached(priority: .userInitiated) {
                transcribeAudioWithWhisper(
                    file: url,
                    shouldCancel: {
                        flag.isCancelled()
                    },
                    progressHandler: { progress in
                        Task { @MainActor [weak self] in
                            self?.setAnalyzeProgress(progress, fileName: url.lastPathComponent)
                        }
                    },
                    onConsoleOutput: { line, source in
                        Task { @MainActor [weak self] in
                            self?.appendActivityConsole(line, source: source)
                        }
                    },
                    onTranscriptSegment: { segment in
                        Task { @MainActor [weak self] in
                            self?.appendGeneratedTranscriptPreviewSegment(segment)
                        }
                    }
                )
            }.value

            await MainActor.run {
                self.applyTranscriptGenerationResult(result)
            }
        }
    }

    private func appendGeneratedTranscriptPreviewSegment(_ segment: TranscriptSegment) {
        guard isGeneratingTranscript else { return }

        let alreadyPresent = transcriptSegments.contains {
            abs($0.start - segment.start) < 0.03 &&
            abs($0.end - segment.end) < 0.03 &&
            $0.text == segment.text
        }
        guard !alreadyPresent else { return }

        transcriptSegments.append(segment)
        transcriptSegments.sort { lhs, rhs in
            if abs(lhs.start - rhs.start) > 0.0001 {
                return lhs.start < rhs.start
            }
            return lhs.end < rhs.end
        }

        let count = transcriptSegments.count
        let noun = count == 1 ? "segment" : "segments"
        transcriptStatusText = "Generating transcript… (\(count) \(noun))"
        analyzeStatusText = transcriptStatusText
        uiMessage = transcriptStatusText
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
