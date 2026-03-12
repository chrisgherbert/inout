import Foundation
import AppKit
import AVFoundation

extension WorkspaceViewModel {    func startClipExport(skipSaveDialog: Bool = false, queueJobID: UUID? = nil, preselectedDestination: URL? = nil) {
        func finalizeQueued(_ status: ClipExportQueueStatus, _ message: String? = nil) {
            completeQueuedJobIfNeeded(queueJobID, status: status, message: message)
        }

        if queueJobID == nil && (isAnalyzing || isExporting || isGeneratingTranscript) {
            enqueueCurrentClipExport(skipSaveDialog: skipSaveDialog)
            return
        }

        guard canRequestClipExport, let sourceURL else {
            finalizeQueued(.failed, "Unable to start export.")
            return
        }
        if !hasVideoTrack && clipEncodingMode != .audioOnly {
            clipEncodingMode = .audioOnly
        }

        clampClipRange()
        guard clipDurationSeconds > 0 else {
            finalizeQueued(.failed, "Invalid clip duration.")
            return
        }

        let defaultName = defaultClipExportFileName(for: sourceURL)

        let destination: URL
        if let preselectedDestination {
            destination = preselectedDestination
            try? FileManager.default.removeItem(at: destination)
        } else if skipSaveDialog {
            let sourceDirectory = sourceURL.deletingLastPathComponent()
            destination = MediaToolUtilities.uniqueUnderscoreIndexedURL(in: sourceDirectory, preferredFileName: defaultName)
        } else {
            guard let chosenDestination = promptClipExportDestination(for: sourceURL, defaultName: defaultName) else {
                finalizeQueued(.cancelled, "Save cancelled.")
                return
            }
            destination = chosenDestination
            try? FileManager.default.removeItem(at: destination)
        }

        if queueJobID == nil {
            let formatLabel = clipEncodingMode == .audioOnly ? clipAudioOnlyFormat.rawValue : selectedClipFormat.rawValue
            let summary = clipJobTitle(skipSaveDialog: skipSaveDialog, mode: clipEncodingMode)
            let subtitle = clipJobSubtitle(
                mode: clipEncodingMode,
                format: formatLabel,
                startSeconds: clipStartSeconds,
                endSeconds: clipEndSeconds
            )
            _ = beginDirectJobTracking(
                fileName: sourceURL.lastPathComponent,
                summary: summary,
                subtitle: subtitle
            )
        }

        if skipSaveDialog && queueJobID == nil {
            DispatchQueue.main.async { [weak self] in
                self?.quickExportFlashToken &+= 1
            }
            playQuickExportSnipSound()
        }

        let exportRunToken = UUID()
        activeClipExportRunToken = exportRunToken
        isExporting = true
        lastActivityState = .running
        exportCancellationRequested = false
        exportProgress = 0
        clearActivityConsole()
        appendActivityConsole(skipSaveDialog ? "Quick clip export started" : "Clip export started", source: "export")
        exportStatusText = queueJobID != nil ? "Running queued clip export…" : (skipSaveDialog ? "Quick exporting clip…" : "Exporting clip…")
        outputURL = nil

        if clipEncodingMode == .audioOnly {
            exportTask = Task { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.exportProgress = 0.1
                    self.exportStatusText = "Exporting audio-only clip…"
                }

                guard let ffmpegURL = self.findFFmpegExecutable() else {
                    await MainActor.run {
                        guard self.activeClipExportRunToken == exportRunToken else { return }
                        self.activeClipExportRunToken = nil
                        self.exportTask = nil
                        self.isExporting = false
                        self.exportProgress = 0
                        self.exportStatusText = "Clip export failed: No ffmpeg executable found."
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    }
                    return
                }

                let start = String(format: "%.3f", self.clipStartSeconds)
                let clipDuration = max(0.001, self.clipEndSeconds - self.clipStartSeconds)
                let durationStr = String(format: "%.3f", clipDuration)
                let bitrateKbps = min(max(64, self.clipAudioBitrateKbps), 320)
                let fadeDuration = min(0.333, clipDuration / 2.0)
                let fadeOutStart = max(0.0, clipDuration - fadeDuration)
                let allowFadeForDuration = clipDuration >= 2.0
                let applyAudioFade = self.clipAudioOnlyAddFadeInOut && allowFadeForDuration
                let codec: String
                switch self.clipAudioOnlyFormat {
                case .mp3:
                    codec = "libmp3lame"
                case .m4a:
                    codec = "aac"
                case .wav:
                    codec = "pcm_s16le"
                }
                let sourceAsset = AVURLAsset(url: sourceURL)
                guard let selectedAudioTrackIndex = self.preferredAudioTrackIndex(for: sourceAsset) else {
                    await MainActor.run {
                        guard self.activeClipExportRunToken == exportRunToken else { return }
                        self.activeClipExportRunToken = nil
                        self.exportTask = nil
                        self.isExporting = false
                        self.exportProgress = 0
                        self.exportStatusText = "Clip export failed: No audio track found in source."
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    }
                    return
                }

                var audioFilters: [String] = []
                if applyAudioFade {
                    audioFilters.append("afade=t=in:st=0:d=\(String(format: "%.3f", fadeDuration))")
                    audioFilters.append("afade=t=out:st=\(String(format: "%.3f", fadeOutStart)):d=\(String(format: "%.3f", fadeDuration))")
                }
                if self.clipAudioOnlyBoostAudio {
                    audioFilters.append("volume=\(self.clipAdvancedBoostAmount.rawValue)dB")
                    audioFilters.append("alimiter=limit=0.988553")
                }

                var args = [
                    "-y",
                    "-hide_banner",
                    "-loglevel", "error",
                    "-ss", start,
                    "-t", durationStr,
                    "-i", sourceURL.path,
                    "-vn"
                ]

                let audioInputRef = "0:a:\(selectedAudioTrackIndex)"
                if !audioFilters.isEmpty {
                    args.append(contentsOf: [
                        "-filter_complex", "[\(audioInputRef)]\(audioFilters.joined(separator: ","))[aout]",
                        "-map", "[aout]"
                    ])
                } else {
                    args.append(contentsOf: ["-map", audioInputRef])
                }

                var outputArgs = [
                    "-c:a", codec
                ]
                if self.clipAudioOnlyFormat != .wav {
                    outputArgs.append(contentsOf: ["-b:a", "\(bitrateKbps)k"])
                }

                let encodeError = await self.runFFmpegProcessWithProgress(
                    executableURL: ffmpegURL,
                    arguments: args + outputArgs + [destination.path],
                    durationSeconds: clipDuration,
                    statusPrefix: "Exporting audio-only clip"
                )

                await MainActor.run {
                    guard self.activeClipExportRunToken == exportRunToken else { return }
                    self.activeClipExportRunToken = nil
                    self.exportTask = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    if self.exportCancellationRequested {
                        self.exportStatusText = "Clip export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                        self.notifyCompletion("Audio-Only Clip Export Stopped", message: self.exportStatusText)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                        return
                    }
                    if let encodeError {
                        self.exportStatusText = "Clip export failed: \(encodeError)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.notifyCompletion("Audio-Only Clip Export Failed", message: self.exportStatusText)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    } else {
                        self.outputURL = destination
                        self.exportStatusText = "Clip export complete: \(destination.lastPathComponent)"
                        if self.clipAudioOnlyAddFadeInOut && !applyAudioFade {
                            self.uiMessage = "Clip export complete: \(destination.lastPathComponent). Audio fade was skipped for clips under 2.0s."
                        } else {
                            self.uiMessage = self.exportStatusText
                        }
                        self.lastActivityState = .success
                        self.notifyCompletion("Audio-Only Clip Export Complete", message: self.uiMessage)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.exportStatusText, outputURL: destination)
                    }
                }
            }
            return
        }

        if clipEncodingMode == .fast {
            guard selectedClipFormat.supportsPassthrough else {
                activeClipExportRunToken = nil
                isExporting = false
                exportStatusText = "Fast mode supports only MP4 and MOV."
                uiMessage = exportStatusText
                lastActivityState = .failed
                finalizeQueued(.failed, exportStatusText)
                return
            }
            let asset = AVURLAsset(url: sourceURL)
            let preset = AVAssetExportPresetPassthrough

            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                activeClipExportRunToken = nil
                isExporting = false
                exportStatusText = "Clip export failed: Unable to create passthrough export session"
                uiMessage = exportStatusText
                lastActivityState = .failed
                finalizeQueued(.failed, exportStatusText)
                return
            }
            activeExportSession = session

            session.outputURL = destination
            session.outputFileType = selectedClipFormat.fileType
            session.shouldOptimizeForNetworkUse = true
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: clipStartSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: clipDurationSeconds, preferredTimescale: 600)
            )

            exportTask = Task { [weak self] in
                guard let self else { return }

                let monitor = Task { [weak self] in
                    while session.status == .waiting || session.status == .exporting {
                        await MainActor.run {
                            self?.exportProgress = Double(session.progress)
                            self?.exportStatusText = "Exporting clip… \(Int((Double(session.progress) * 100).rounded()))%"
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
                    guard self.activeClipExportRunToken == exportRunToken else { return }
                    self.activeClipExportRunToken = nil
                    self.exportTask = nil
                    self.activeExportSession = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    if self.exportCancellationRequested {
                        self.exportStatusText = "Clip export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                        self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                        return
                    }
                    switch session.status {
                    case .completed:
                        self.outputURL = destination
                        self.exportStatusText = "Clip export complete: \(destination.lastPathComponent)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .success
                        self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.exportStatusText, outputURL: destination)
                    case .failed:
                        self.exportStatusText = "Clip export failed: \(session.error?.localizedDescription ?? "Unknown error")"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    case .cancelled:
                        self.exportStatusText = "Clip export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                        self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                    default:
                        self.exportStatusText = "Clip export ended with status: \(session.status.rawValue)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    }
                }
            }
            return
        }

        exportTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.exportProgress = 0.1
                self.exportStatusText = "Encoding compressed clip…"
            }

            guard let ffmpegURL = self.findFFmpegExecutable() else {
                await MainActor.run {
                    guard self.activeClipExportRunToken == exportRunToken else { return }
                    self.activeClipExportRunToken = nil
                    self.exportTask = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    self.exportStatusText = "Clip export failed: No ffmpeg executable found."
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                    self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                }
                return
            }

            let bitrateKbps = max(500, Int((self.clipVideoBitrateMbps * 1000.0).rounded()))
            let audioBitrateKbps = min(max(64, self.clipAudioBitrateKbps), 320)
            // CRITICAL REGRESSION GUARD:
            // DO NOT REORDER THIS SEEK SEQUENCE.
            // Keep this hybrid seek order for advanced ffmpeg exports:
            //   -ss <coarse pre-roll> -i <source> -ss <fine offset> -t <duration>
            // Using only post-input seek here has repeatedly reintroduced a black
            // first frame on long-GOP sources in both captioned and non-captioned paths.
            // Any caption path must reuse this exact order as well.
            let decoderPreRollSeconds = 2.5
            let coarseSeekSeconds = max(0.0, self.clipStartSeconds - decoderPreRollSeconds)
            let fineSeekSeconds = max(0.0, self.clipStartSeconds - coarseSeekSeconds)
            let coarseSeek = String(format: "%.6f", coarseSeekSeconds)
            let fineSeek = String(format: "%.6f", fineSeekSeconds)
            let clipDuration = max(0.001, self.clipEndSeconds - self.clipStartSeconds)
            let durationStr = String(format: "%.3f", clipDuration)
            let fadeDuration = min(0.333, clipDuration / 2.0)
            let fadeOutStart = max(0.0, clipDuration - fadeDuration)
            let allowFadeForDuration = clipDuration >= 2.0
            let applyAudioFade = self.clipAdvancedAddFadeInOut && allowFadeForDuration
            let isWebM = self.selectedClipFormat == .webm
            let sourceAsset = AVURLAsset(url: sourceURL)
            let selectedAudioTrackIndex = self.preferredAudioTrackIndex(for: sourceAsset)
            let hasSourceAudio = (selectedAudioTrackIndex != nil)
            let videoCodec = isWebM ? "libvpx-vp9" : (self.clipAdvancedVideoCodec == .hevc ? "libx265" : "libx264")
            let audioCodec = isWebM ? "libopus" : "aac"
            var videoFilters: [String] = []
            var audioFilters: [String] = []
            // Baseline args for advanced export. For captioned exports we run this
            // exact baseline path to a temp clip first, then do a dedicated burn pass.
            var baselineArgs = [
                "-y",
                "-hide_banner",
                "-loglevel", "error",
                "-ss", coarseSeek,
                "-i", sourceURL.path,
                "-ss", fineSeek,
                "-t", durationStr,
                "-map", "0:v:0",
                "-c:v", videoCodec,
                "-preset", self.clipCompatibleSpeedPreset.ffmpegPreset,
                "-pix_fmt", "yuv420p",
                "-b:v", "\(bitrateKbps)k"
            ]

            if let scaleFilter = self.clipCompatibleMaxResolution.scaleFilter {
                videoFilters.append(scaleFilter)
            }

            if applyAudioFade && hasSourceAudio {
                audioFilters.append("afade=t=in:st=0:d=\(String(format: "%.3f", fadeDuration))")
                audioFilters.append("afade=t=out:st=\(String(format: "%.3f", fadeOutStart)):d=\(String(format: "%.3f", fadeDuration))")
            }

            if self.clipAdvancedBoostAudio && hasSourceAudio {
                audioFilters.append("volume=\(self.clipAdvancedBoostAmount.rawValue)dB")
                audioFilters.append("alimiter=limit=0.988553")
            }

            if let selectedAudioTrackIndex {
                let audioInputRef = "0:a:\(selectedAudioTrackIndex)"
                if !audioFilters.isEmpty {
                    baselineArgs.append(contentsOf: [
                        "-filter_complex", "[\(audioInputRef)]\(audioFilters.joined(separator: ","))[aout]",
                        "-map", "[aout]"
                    ])
                } else {
                    baselineArgs.append(contentsOf: ["-map", audioInputRef])
                }
                baselineArgs.append(contentsOf: [
                    "-c:a", audioCodec,
                    "-b:a", "\(audioBitrateKbps)k"
                ])
            }

            if self.selectedClipFormat == .mp4 || self.selectedClipFormat == .mov {
                baselineArgs.append(contentsOf: ["-movflags", "+faststart"])
            }

            var encodeError: String? = nil
            if self.clipAdvancedBurnInCaptions {
                // CAPTION PIPELINE REGRESSION GUARD:
                // Keep captioned exports as a strict staged-base 2-step flow:
                //   1) Create a staged base clip using the same hybrid seek order as advanced export
                //      (-ss coarse -> -i source -> -ss fine -> -t duration).
                //   2) Generate captions from staged base audio and burn onto that same staged base video.
                //
                // This prevents:
                // - recurring black-first-frame regressions from seek-order drift, and
                // - fixed subtitle lead/lag offsets from mixed time origins.
                //
                // Do NOT collapse caption exports into a direct source->burn single pass
                // unless both black-frame behavior and sync are re-validated on long-GOP/VFR sources.
                await MainActor.run {
                    self.exportProgress = max(self.exportProgress, 0.12)
                    self.exportStatusText = "Generating captions…"
                }
                let captionStageDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bvt-caption-stage-\(UUID().uuidString)", isDirectory: true)
                var captionStageReady = true
                do {
                    try FileManager.default.createDirectory(at: captionStageDirectory, withIntermediateDirectories: true)
                } catch {
                    captionStageReady = false
                    encodeError = "Unable to create temporary caption stage directory: \(error.localizedDescription)"
                }
                defer {
                    try? FileManager.default.removeItem(at: captionStageDirectory)
                }

                if captionStageReady {
                    let stagedBaseURL = captionStageDirectory.appendingPathComponent("base.\(self.selectedClipFormat.fileExtension)")
                    var stageArgs = baselineArgs
                    if !videoFilters.isEmpty {
                        stageArgs.append(contentsOf: ["-vf", videoFilters.joined(separator: ",")])
                    }
                    stageArgs.append(stagedBaseURL.path)

                    let stageError = await self.runFFmpegProcessWithProgress(
                        executableURL: ffmpegURL,
                        arguments: stageArgs,
                        durationSeconds: clipDuration,
                        statusPrefix: "Preparing base clip",
                        progressRange: 0.10...0.50
                    )

                    if self.exportCancellationRequested {
                        encodeError = nil
                    } else if let stageError {
                        encodeError = stageError
                    } else {
                        let captionPrep = await self.prepareWhisperBurnInCaptions(
                            sourceURL: stagedBaseURL,
                            ffmpegURL: ffmpegURL,
                            coarseSeekSeconds: 0.0,
                            fineSeekSeconds: 0.0,
                            durationSeconds: clipDuration
                        )

                        if self.exportCancellationRequested {
                            encodeError = nil
                        } else if let prepared = captionPrep.preparation {
                            defer {
                                try? FileManager.default.removeItem(at: prepared.tempDirectory)
                            }

                            let cueCount = self.countSRTCues(at: prepared.srtURL)
                            if cueCount <= 0 {
                                encodeError = "Caption generation produced 0 cues. SRT: \(prepared.srtURL.path)"
                            } else {
                                await MainActor.run {
                                    self.exportStatusText = "Encoding captioned clip… (\(cueCount) cues)"
                                }

                                var burnArgs = [
                                    "-y",
                                    "-hide_banner",
                                    "-loglevel", "error",
                                    "-i", stagedBaseURL.path,
                                    "-map", "0:v:0",
                                    "-c:v", videoCodec,
                                    "-preset", self.clipCompatibleSpeedPreset.ffmpegPreset,
                                    "-pix_fmt", "yuv420p",
                                    "-b:v", "\(bitrateKbps)k",
                                    "-vf", MediaToolUtilities.subtitlesFilterArgument(path: prepared.srtURL.path, style: self.clipAdvancedCaptionStyle),
                                    "-map", "0:a:0?",
                                    "-c:a", "copy"
                                ]
                                if self.selectedClipFormat == .mp4 || self.selectedClipFormat == .mov {
                                    burnArgs.append(contentsOf: ["-movflags", "+faststart"])
                                }
                                burnArgs.append(destination.path)

                                encodeError = await self.runFFmpegProcessWithProgress(
                                    executableURL: ffmpegURL,
                                    arguments: burnArgs,
                                    durationSeconds: clipDuration,
                                    statusPrefix: "Encoding captioned clip",
                                    progressRange: 0.55...1.0
                                )
                            }
                        } else {
                            encodeError = captionPrep.error ?? "Unknown caption generation failure."
                        }
                    }
                }
            } else {
                var args = baselineArgs
                if !videoFilters.isEmpty {
                    args.append(contentsOf: ["-vf", videoFilters.joined(separator: ",")])
                }
                args.append(destination.path)
                encodeError = await self.runFFmpegProcessWithProgress(
                    executableURL: ffmpegURL,
                    arguments: args,
                    durationSeconds: clipDuration,
                    statusPrefix: "Encoding advanced clip"
                )
            }

            await MainActor.run {
                guard self.activeClipExportRunToken == exportRunToken else { return }
                self.activeClipExportRunToken = nil
                self.exportTask = nil
                self.isExporting = false
                self.exportProgress = 0
                if self.exportCancellationRequested {
                    self.exportStatusText = "Clip export cancelled"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .cancelled
                    self.notifyCompletion("Compatible Clip Export Stopped", message: self.exportStatusText)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                    return
                }
                if let encodeError {
                    self.exportStatusText = "Clip export failed: \(encodeError)"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                    self.notifyCompletion("Compatible Clip Export Failed", message: self.exportStatusText)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                } else {
                    self.outputURL = destination
                    self.exportStatusText = "Clip export complete: \(destination.lastPathComponent)"
                    if self.clipAdvancedAddFadeInOut && !applyAudioFade {
                        self.uiMessage = "Clip export complete: \(destination.lastPathComponent). Audio fade was skipped for clips under 2.0s."
                    } else {
                        self.uiMessage = self.exportStatusText
                    }
                    self.lastActivityState = .success
                    self.notifyCompletion("Compatible Clip Export Complete", message: self.uiMessage)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.exportStatusText, outputURL: destination)
                }
            }
        }
    }

    private struct BurnInCaptionPreparation {
        let srtURL: URL
        let tempDirectory: URL
    }

    private func prepareWhisperBurnInCaptions(
        sourceURL: URL,
        ffmpegURL: URL,
        coarseSeekSeconds: Double,
        fineSeekSeconds: Double,
        durationSeconds: Double
    ) async -> (preparation: BurnInCaptionPreparation?, error: String?) {
        guard let whisperURL = findWhisperExecutable(),
              let whisperModelURL = findWhisperModel() else {
            return (nil, "Whisper resources are not bundled. Rebuild the app with bundled whisper-cli and model.")
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bvt-burnin-captions-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        } catch {
            return (nil, "Unable to create temporary caption directory: \(error.localizedDescription)")
        }

        let wavURL = tempDirectory.appendingPathComponent("caption-audio.wav")
        let outputPrefix = tempDirectory.appendingPathComponent("caption-track")
        let srtURL = tempDirectory.appendingPathComponent("caption-track.srt")
        // Keep caption-audio extraction time-origin identical to advanced clip export:
        // -ss <coarse pre-roll> -i <source> -ss <fine offset> -t <duration>
        // This prevents fixed subtitle offsets (captions consistently early/late).
        let coarseSeek = String(format: "%.6f", max(0.0, coarseSeekSeconds))
        let fineSeek = String(format: "%.6f", max(0.0, fineSeekSeconds))
        let duration = String(format: "%.3f", max(0.001, durationSeconds))

        let extractError = await runFFmpegProcessWithProgress(
            executableURL: ffmpegURL,
            arguments: [
                "-y",
                "-hide_banner",
                "-loglevel", "error",
                "-ss", coarseSeek,
                "-i", sourceURL.path,
                "-ss", fineSeek,
                "-t", duration,
                "-vn",
                "-ac", "1",
                "-ar", "16000",
                "-f", "wav",
                wavURL.path
            ]
            ,
            durationSeconds: max(0.001, durationSeconds),
            statusPrefix: "Generating captions",
            progressRange: 0.10...0.35
        )
        if exportCancellationRequested {
            return (nil, "Cancelled")
        }
        if let extractError {
            return (nil, "Caption audio extraction failed: \(extractError)")
        }

        let whisperArgs = [
            "-m", whisperModelURL.path,
            "-f", wavURL.path,
            "-of", outputPrefix.path,
            "-osrt",
            "-pp"
        ]
        let whisperError = await runWhisperProcessWithProgress(
            executableURL: whisperURL,
            arguments: whisperArgs,
            statusPrefix: "Generating captions",
            progressRange: 0.35...0.55
        )
        if exportCancellationRequested {
            return (nil, "Cancelled")
        }

        if whisperError != nil {
            // Retry with CPU-safe flags; some runtime combinations fail on first accelerated attempt.
            let retryError = await runWhisperProcessWithProgress(
                executableURL: whisperURL,
                arguments: [
                    "-ng",
                    "-nfa"
                ] + whisperArgs,
                statusPrefix: "Generating captions",
                progressRange: 0.35...0.55
            )
            if exportCancellationRequested {
                return (nil, "Cancelled")
            }
            if let retryError {
                return (nil, "Whisper transcription failed: \(retryError)")
            }
        }

        guard FileManager.default.fileExists(atPath: srtURL.path) else {
            return (nil, "Whisper did not produce subtitle output.")
        }

        do {
            let rawSRT = try String(contentsOf: srtURL, encoding: .utf8)
            let cueCount = rawSRT.components(separatedBy: .newlines).filter { $0.contains("-->") }.count
            guard cueCount > 0 else {
                return (nil, "Whisper produced subtitle file with 0 cues.")
            }
        } catch {
            return (nil, "Unable to validate subtitle file: \(error.localizedDescription)")
        }

        return (BurnInCaptionPreparation(srtURL: srtURL, tempDirectory: tempDirectory), nil)
    }

    func findFFmpegExecutable() -> URL? {
        ToolDiscoveryUtilities.findExecutable(named: "ffmpeg")
    }

    func findFFprobeExecutable() -> URL? {
        ToolDiscoveryUtilities.findExecutable(named: "ffprobe")
    }

    func revealOutput() {
        guard let outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }
}
