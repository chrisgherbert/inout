import Foundation
import AppKit
import AVFoundation

extension WorkspaceViewModel {
    func stopExport() {
        guard isExporting else { return }
        let queueJobID = activeQueuedJobID
        exportCancellationRequested = true
        activeClipExportRunToken = nil
        activeExportSession?.cancelExport()
        if let process = activeProcess, process.isRunning {
            process.terminate()
        }
        exportTask?.cancel()
        exportTask = nil
        activeExportSession = nil
        activeProcess = nil
        isExporting = false
        exportProgress = 0
        exportStatusText = "Export cancelled"
        uiMessage = exportStatusText
        lastActivityState = .cancelled
        completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: "Stopped by user.")
    }

    func startExport(queueJobID: UUID? = nil, preselectedDestination: URL? = nil) {
        if queueJobID == nil && (isAnalyzing || isExporting || isGeneratingTranscript) {
            enqueueCurrentAudioExport()
            return
        }
        guard canRequestAudioExport, let sourceURL else {
            completeQueuedJobIfNeeded(queueJobID, status: .failed, message: "Unable to start audio export.")
            return
        }

        let destination: URL
        if let preselectedDestination {
            destination = preselectedDestination
        } else {
            guard let chosenDestination = promptAudioExportDestination(for: sourceURL) else {
                completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: "Save cancelled.")
                return
            }
            destination = chosenDestination
        }

        if queueJobID == nil {
            _ = beginDirectJobTracking(
                fileName: sourceURL.lastPathComponent,
                summary: audioExportJobTitle(format: selectedAudioFormat),
                subtitle: audioExportJobSubtitle(bitrateKbps: exportAudioBitrateKbps)
            )
        }

        isExporting = true
        lastActivityState = .running
        exportCancellationRequested = false
        exportProgress = 0
        clearActivityConsole()
        appendActivityConsole("Audio export started", source: "export")
        exportStatusText = "Preparing export…"
        outputURL = nil

        let asset = AVURLAsset(url: sourceURL)
        try? FileManager.default.removeItem(at: destination)

        exportTask = Task { [weak self] in
            guard let self else { return }

            if self.selectedAudioFormat == .m4a {
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    await MainActor.run {
                        self.exportTask = nil
                        self.isExporting = false
                        self.exportStatusText = "Export failed: Unable to create export session"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    }
                    return
                }
                await MainActor.run {
                    self.activeExportSession = session
                }

                session.outputURL = destination
                session.outputFileType = .m4a
                session.shouldOptimizeForNetworkUse = true

                let monitor = Task { [weak self] in
                    while session.status == .waiting || session.status == .exporting {
                        await MainActor.run {
                            self?.exportProgress = Double(session.progress)
                            self?.exportStatusText = "Exporting M4A… \(Int((Double(session.progress) * 100).rounded()))%"
                        }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }

                await withCheckedContinuation { continuation in
                    session.exportAsynchronously {
                        continuation.resume()
                    }
                }

                monitor.cancel()

                await MainActor.run {
                    self.exportTask = nil
                    self.activeExportSession = nil
                    self.isExporting = false
                    self.exportProgress = 0

                    if self.exportCancellationRequested {
                        self.exportStatusText = "Export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                        self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                        return
                    }

                    switch session.status {
                    case .completed:
                        self.outputURL = destination
                        self.exportStatusText = "Export complete: \(destination.lastPathComponent)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .success
                        self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.exportStatusText, outputURL: destination)
                    case .failed:
                        self.exportStatusText = "Export failed: \(session.error?.localizedDescription ?? "Unknown error")"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    case .cancelled:
                        self.exportStatusText = "Export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                        self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                    default:
                        self.exportStatusText = "Export ended with status: \(session.status.rawValue)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    }
                }
                return
            }

            await MainActor.run {
                self.exportProgress = 0.1
                self.exportStatusText = "Encoding MP3…"
            }

            let mp3Error: String?
            if let ffmpegURL = self.findFFmpegExecutable() {
                mp3Error = await self.runFFmpegProcessWithProgress(
                    executableURL: ffmpegURL,
                    arguments: [
                        "-y",
                        "-hide_banner",
                        "-loglevel", "error",
                        "-i", sourceURL.path,
                        "-vn",
                        "-acodec", "libmp3lame",
                        "-b:a", "\(max(64, self.exportAudioBitrateKbps))k",
                        destination.path
                    ],
                    durationSeconds: max(0.001, self.sourceDurationSeconds),
                    statusPrefix: "Encoding MP3"
                )
            } else {
                mp3Error = "No ffmpeg executable found. Bundle ffmpeg at Contents/Resources/ffmpeg or install it on this Mac."
            }

            await MainActor.run {
                self.exportTask = nil
                self.isExporting = false
                self.exportProgress = 0
                if self.exportCancellationRequested {
                    self.exportStatusText = "Export cancelled"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .cancelled
                    self.notifyCompletion("MP3 Export Stopped", message: self.exportStatusText)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                    return
                }
                if let mp3Error {
                    self.exportStatusText = "MP3 export failed: \(mp3Error)"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                    self.notifyCompletion("MP3 Export Failed", message: self.exportStatusText)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                } else {
                    self.outputURL = destination
                    self.exportStatusText = "Export complete: \(destination.lastPathComponent)"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .success
                    self.notifyCompletion("MP3 Export Complete", message: self.exportStatusText)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.exportStatusText, outputURL: destination)
                }
            }
        }
    }
}
