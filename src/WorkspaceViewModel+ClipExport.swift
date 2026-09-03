import Foundation
import AppKit
import AVFoundation
import InOutCore

extension WorkspaceViewModel {
    func startClipExport(
        skipSaveDialog: Bool = false,
        queueJobID: UUID? = nil,
        preselectedDestination: URL? = nil,
        configOverride: QueuedClipExportConfig? = nil
    ) {
        func finalizeQueued(_ status: ClipExportQueueStatus, _ message: String? = nil) {
            completeQueuedJobIfNeeded(queueJobID, status: status, message: message)
        }

        if configOverride == nil,
           queueJobID == nil,
           (isAnalyzing || isExporting || isGeneratingTranscript) {
            enqueueCurrentClipExport(skipSaveDialog: skipSaveDialog)
            return
        }

        guard let sourceURL, !isGeneratingTranscript else {
            finalizeQueued(.failed, "Unable to start export.")
            return
        }
        if configOverride == nil, !canRequestClipExport {
            finalizeQueued(.failed, "Unable to start export.")
            return
        }
        if configOverride == nil {
            if !hasVideoTrack && clipEncodingMode != .audioOnly {
                clipEncodingMode = .audioOnly
            }
            clampClipRange()
        }
        let config = configOverride ?? queuedClipExportConfigSnapshot()
        guard config.clipFramingAspectRatio == .original || config.sourceVideoDimensions != nil else {
            let message = "Unable to determine the source dimensions required for framing."
            finalizeQueued(.failed, message)
            uiMessage = message
            return
        }
        let captionTranscriptSnapshot: [TranscriptSegment]? = {
            guard config.clipAdvancedBurnInCaptions,
                  hasCachedTranscript,
                  (sourceInfo?.audioStreamCount ?? 1) <= 1,
                  transcriptHasWordTimings(transcriptSegments) else { return nil }
            return transcriptSegments
        }()
        let exportDuration = max(0, config.clipEndSeconds - config.clipStartSeconds)
        let exportName = config.isFullSourceConversion
            ? (config.clipEncodingMode == .audioOnly ? "Audio export" : "Video export")
            : "Clip export"
        guard exportDuration > 0 else {
            finalizeQueued(.failed, "Invalid clip duration.")
            return
        }

        let defaultName = defaultClipExportFileName(for: sourceURL, config: config)

        let destination: URL
        if let preselectedDestination {
            destination = preselectedDestination
        } else if skipSaveDialog {
            let sourceDirectory = sourceURL.deletingLastPathComponent()
            destination = MediaToolUtilities.uniqueUnderscoreIndexedURL(in: sourceDirectory, preferredFileName: defaultName)
        } else {
            guard let chosenDestination = promptClipExportDestination(
                for: sourceURL,
                defaultName: defaultName,
                config: config
            ) else {
                finalizeQueued(.cancelled, "Save cancelled.")
                return
            }
            destination = chosenDestination
        }

        guard destination.standardizedFileURL != sourceURL.standardizedFileURL else {
            finalizeQueued(.failed, "The export destination cannot replace the source file.")
            uiMessage = "Choose a different export filename so the source media is preserved."
            return
        }
        try? FileManager.default.removeItem(at: destination)

        if queueJobID == nil {
            let formatLabel = config.clipEncodingMode == .audioOnly
                ? config.clipAudioOnlyFormat.rawValue
                : config.selectedClipFormat.rawValue
            let summary = config.isFullSourceConversion
                ? (config.clipEncodingMode == .audioOnly ? "Audio Export" : "Video Export")
                : clipJobTitle(skipSaveDialog: skipSaveDialog, mode: config.clipEncodingMode)
            let subtitle = clipJobSubtitle(
                mode: config.clipEncodingMode,
                format: formatLabel,
                startSeconds: config.clipStartSeconds,
                endSeconds: config.clipEndSeconds
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
        exportCancelFlag.reset()
        exportProgress = 0
        clearActivityConsole()
        appendActivityConsole("\(exportName) started", source: "export")
        exportStatusText = queueJobID != nil ? "Running queued \(exportName.lowercased())…" : "\(exportName) in progress…"
        outputURL = nil

        if config.clipEncodingMode == .audioOnly {
            exportTask = Task { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.exportProgress = 0.1
                    self.exportStatusText = config.isFullSourceConversion ? "Exporting audio…" : "Exporting audio-only clip…"
                }

                guard let ffmpegURL = self.findFFmpegExecutable() else {
                    await MainActor.run {
                        guard self.activeClipExportRunToken == exportRunToken else { return }
                        self.activeClipExportRunToken = nil
                        self.exportTask = nil
                        self.isExporting = false
                        self.exportProgress = 0
                        self.exportStatusText = "\(exportName) failed: No ffmpeg executable found."
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.notifyCompletion("\(exportName.capitalized) Failed", message: self.exportStatusText, outcome: .failed)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    }
                    return
                }

                let start = String(format: "%.3f", config.clipStartSeconds)
                let clipDuration = max(0.001, config.clipEndSeconds - config.clipStartSeconds)
                let durationStr = String(format: "%.3f", clipDuration)
                let bitrateKbps = min(max(64, config.clipAudioBitrateKbps), 320)
                let fadeDuration = min(0.333, clipDuration / 2.0)
                let fadeOutStart = max(0.0, clipDuration - fadeDuration)
                let allowFadeForDuration = clipDuration >= 2.0
                let applyAudioFade = config.clipAudioOnlyAddFadeInOut && allowFadeForDuration
                let codec: String
                switch config.clipAudioOnlyFormat {
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
                        self.exportStatusText = "\(exportName) failed: No audio track found in source."
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.notifyCompletion("\(exportName.capitalized) Failed", message: self.exportStatusText, outcome: .failed)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    }
                    return
                }

                var audioFilters: [String] = []
                if applyAudioFade {
                    audioFilters.append("afade=t=in:st=0:d=\(String(format: "%.3f", fadeDuration))")
                    audioFilters.append("afade=t=out:st=\(String(format: "%.3f", fadeOutStart)):d=\(String(format: "%.3f", fadeDuration))")
                }
                if config.clipAudioOnlyBoostAudio {
                    audioFilters.append("volume=\(config.clipAdvancedBoostAmount.rawValue)dB")
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
                if config.clipAudioOnlyFormat != .wav {
                    outputArgs.append(contentsOf: ["-b:a", "\(bitrateKbps)k"])
                }

                let encodeError = await self.runFFmpegProcessWithProgress(
                    executableURL: ffmpegURL,
                    arguments: args + outputArgs + [destination.path],
                    durationSeconds: clipDuration,
                    statusPrefix: config.isFullSourceConversion ? "Exporting audio" : "Exporting audio-only clip"
                )

                await MainActor.run {
                    guard self.activeClipExportRunToken == exportRunToken else { return }
                    self.activeClipExportRunToken = nil
                    self.exportTask = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    if self.exportCancellationRequested {
                        self.exportStatusText = "\(exportName) cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                        self.notifyCompletion("\(exportName.capitalized) Stopped", message: self.exportStatusText, outcome: .cancelled)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                        return
                    }
                    if let encodeError {
                        self.exportStatusText = "\(exportName) failed: \(encodeError)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.notifyCompletion("\(exportName.capitalized) Failed", message: self.exportStatusText, outcome: .failed)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    } else {
                        self.outputURL = destination
                        self.exportStatusText = "\(exportName) complete: \(destination.lastPathComponent)"
                        if config.clipAudioOnlyAddFadeInOut && !applyAudioFade {
                            self.uiMessage = "\(exportName) complete: \(destination.lastPathComponent). Audio fade was skipped for media under 2.0s."
                        } else {
                            self.uiMessage = self.exportStatusText
                        }
                        self.lastActivityState = .success
                        self.notifyCompletion("\(exportName.capitalized) Complete", message: self.uiMessage)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.exportStatusText, outputURL: destination)
                    }
                }
            }
            return
        }

        if config.clipEncodingMode == .fast {
            guard config.selectedClipFormat.supportsPassthrough else {
                activeClipExportRunToken = nil
                isExporting = false
                exportStatusText = "Fast mode supports only MP4 and MOV."
                uiMessage = exportStatusText
                lastActivityState = .failed
                finalizeQueued(.failed, exportStatusText)
                return
            }
            let asset = AVURLAsset(
                url: sourceURL,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )

            exportTask = Task { [weak self] in
                guard let self else { return }

                let exportTimeRange = await FastExportUtilities.exportTimeRange(
                    for: asset,
                    selectedStartSeconds: config.clipStartSeconds,
                    selectedEndSeconds: config.clipEndSeconds
                )
                guard !Task.isCancelled,
                      self.activeClipExportRunToken == exportRunToken else { return }

                let actualStart = CMTimeGetSeconds(exportTimeRange.start)
                let actualEnd = CMTimeGetSeconds(exportTimeRange.end)
                if actualStart < config.clipStartSeconds - 0.000_001 ||
                    actualEnd > config.clipEndSeconds + 0.000_001 {
                    self.appendActivityConsole(
                        String(
                            format: "Expanded Fast export to safe frame boundaries: %.3f–%.3f seconds (requested %.3f–%.3f)",
                            actualStart,
                            actualEnd,
                            config.clipStartSeconds,
                            config.clipEndSeconds
                        ),
                        source: "export"
                    )
                }

                guard let session = AVAssetExportSession(
                    asset: asset,
                    presetName: AVAssetExportPresetPassthrough
                ) else {
                    self.activeClipExportRunToken = nil
                    self.exportTask = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    self.exportStatusText = "Clip export failed: Unable to create passthrough export session"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                    self.notifyCompletion("Clip Export Failed", message: self.exportStatusText, outcome: .failed)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    return
                }
                self.activeExportSession = session
                session.outputURL = destination
                session.outputFileType = config.selectedClipFormat.fileType
                session.shouldOptimizeForNetworkUse = true
                session.timeRange = exportTimeRange

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
                        self.notifyCompletion("Clip Export Stopped", message: self.exportStatusText, outcome: .cancelled)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                        return
                    }
                    switch session.status {
                    case .completed:
                        self.outputURL = destination
                        self.exportStatusText = "Clip export complete: \(destination.lastPathComponent)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .success
                        self.notifyCompletion("Clip Export Complete", message: self.exportStatusText)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.exportStatusText, outputURL: destination)
                    case .failed:
                        self.exportStatusText = "Clip export failed: \(session.error?.localizedDescription ?? "Unknown error")"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.notifyCompletion("Clip Export Failed", message: self.exportStatusText, outcome: .failed)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                    case .cancelled:
                        self.exportStatusText = "Clip export cancelled"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .cancelled
                        self.notifyCompletion("Clip Export Stopped", message: self.exportStatusText, outcome: .cancelled)
                        self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                    default:
                        self.exportStatusText = "Clip export ended with status: \(session.status.rawValue)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                        self.notifyCompletion("Clip Export Failed", message: self.exportStatusText, outcome: .failed)
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
                self.exportStatusText = config.isFullSourceConversion ? "Encoding video…" : "Encoding compressed clip…"
            }

            guard let ffmpegURL = self.findFFmpegExecutable() else {
                await MainActor.run {
                    guard self.activeClipExportRunToken == exportRunToken else { return }
                    self.activeClipExportRunToken = nil
                    self.exportTask = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    self.exportStatusText = "\(exportName) failed: No ffmpeg executable found."
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                    self.notifyCompletion("\(exportName.capitalized) Failed", message: self.exportStatusText, outcome: .failed)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                }
                return
            }

            let bitrateKbps = max(500, Int((config.clipVideoBitrateMbps * 1000.0).rounded()))
            let audioBitrateKbps = min(max(64, config.clipAudioBitrateKbps), 320)
            // CRITICAL REGRESSION GUARD:
            // DO NOT REORDER THIS SEEK SEQUENCE.
            // Keep this hybrid seek order for advanced ffmpeg exports:
            //   -ss <coarse pre-roll> -i <source> -ss <fine offset> -t <duration>
            // Using only post-input seek here has repeatedly reintroduced a black
            // first frame on long-GOP sources in both captioned and non-captioned paths.
            // Any caption path must reuse this exact order as well.
            let decoderPreRollSeconds = 2.5
            let coarseSeekSeconds = max(0.0, config.clipStartSeconds - decoderPreRollSeconds)
            let fineSeekSeconds = max(0.0, config.clipStartSeconds - coarseSeekSeconds)
            let coarseSeek = String(format: "%.6f", coarseSeekSeconds)
            let fineSeek = String(format: "%.6f", fineSeekSeconds)
            let clipDuration = max(0.001, config.clipEndSeconds - config.clipStartSeconds)
            let durationStr = String(format: "%.3f", clipDuration)
            let fadeDuration = min(0.333, clipDuration / 2.0)
            let fadeOutStart = max(0.0, clipDuration - fadeDuration)
            let allowFadeForDuration = clipDuration >= 2.0
            let applyAudioFade = config.clipAdvancedAddFadeInOut && allowFadeForDuration
            let audioFadeInStart = fineSeekSeconds
            let audioFadeOutStart = fineSeekSeconds + fadeOutStart
            let isWebM = config.selectedClipFormat == .webm
            let sourceAsset = AVURLAsset(url: sourceURL)
            let selectedAudioTrackIndex = self.preferredAudioTrackIndex(for: sourceAsset)
            let hasSourceAudio = (selectedAudioTrackIndex != nil)
            let audioCodec = isWebM ? "libopus" : "aac"
            let finalVideoEncodingPlan = videoExportEncodingPlan(
                format: config.selectedClipFormat,
                codec: config.clipAdvancedVideoCodec,
                speed: config.clipCompatibleSpeedPreset,
                pass: .final
            )
            let captionStageVideoEncodingPlan = videoExportEncodingPlan(
                format: config.selectedClipFormat,
                codec: config.clipAdvancedVideoCodec,
                speed: config.clipCompatibleSpeedPreset,
                pass: .captionStage
            )
            var videoFilters: [String] = []
            var audioFilters: [String] = []

            if config.clipFramingAspectRatio != .original,
               let sourceDimensions = config.sourceVideoDimensions,
               let framingFilter = mediaFramingVideoFilter(
                    aspectRatio: config.clipFramingAspectRatio,
                    mode: config.clipFramingMode,
                    cropAlignment: config.clipFramingCropAlignment,
                    customCropX: config.clipFramingCustomCropX,
                    customCropY: config.clipFramingCustomCropY,
                    source: sourceDimensions,
                    maximumShortEdge: config.clipCompatibleMaxResolution.maximumShortEdge
               ) {
                videoFilters.append(framingFilter)
            } else if let scaleFilter = config.clipCompatibleMaxResolution.scaleFilter {
                videoFilters.append(scaleFilter)
            }

            if applyAudioFade && hasSourceAudio {
                // In the advanced export path, the fine seek is an output-side seek.
                // Audio filters still see the coarse-seeked timeline, so fade timestamps
                // need to be offset by the fine seek to land on the exported clip edges.
                audioFilters.append("afade=t=in:st=\(String(format: "%.3f", audioFadeInStart)):d=\(String(format: "%.3f", fadeDuration))")
                audioFilters.append("afade=t=out:st=\(String(format: "%.3f", audioFadeOutStart)):d=\(String(format: "%.3f", fadeDuration))")
            }

            if config.clipAdvancedBoostAudio && hasSourceAudio {
                audioFilters.append("volume=\(config.clipAdvancedBoostAmount.rawValue)dB")
                audioFilters.append("alimiter=limit=0.988553")
            }

            func videoEncodingArguments(for plan: VideoExportEncodingPlan) -> [String] {
                ["-c:v", plan.encoder]
                    + plan.options
                    + ["-pix_fmt", "yuv420p", "-b:v", "\(bitrateKbps)k"]
            }

            // Both normal and caption-staging exports share the same seek, mapping,
            // filtering, and muxing path; only the video encoder policy differs.
            func baselineArguments(
                videoEncodingPlan: VideoExportEncodingPlan,
                includeFastStart: Bool
            ) -> [String] {
                var args = [
                    "-y",
                    "-hide_banner",
                    "-loglevel", "error",
                    "-ss", coarseSeek,
                    "-i", sourceURL.path,
                    "-ss", fineSeek,
                    "-t", durationStr,
                    "-map", "0:v:0"
                ]
                args.append(contentsOf: videoEncodingArguments(for: videoEncodingPlan))

                if let selectedAudioTrackIndex {
                    let audioInputRef = "0:a:\(selectedAudioTrackIndex)"
                    if !audioFilters.isEmpty {
                        args.append(contentsOf: [
                            "-filter_complex", "[\(audioInputRef)]\(audioFilters.joined(separator: ","))[aout]",
                            "-map", "[aout]"
                        ])
                    } else {
                        args.append(contentsOf: ["-map", audioInputRef])
                    }
                    args.append(contentsOf: [
                        "-c:a", audioCodec,
                        "-b:a", "\(audioBitrateKbps)k"
                    ])
                }

                if includeFastStart,
                   (config.selectedClipFormat == .mp4 || config.selectedClipFormat == .mov) {
                    args.append(contentsOf: ["-movflags", "+faststart"])
                }
                return args
            }

            let baselineArgs = baselineArguments(
                videoEncodingPlan: finalVideoEncodingPlan,
                includeFastStart: true
            )

            var encodeError: String? = nil
            if config.clipAdvancedBurnInCaptions {
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
                    let captionStageExtension = isWebM ? "mkv" : config.selectedClipFormat.fileExtension
                    let stagedBaseURL = captionStageDirectory.appendingPathComponent("base.\(captionStageExtension)")
                    var stageArgs = baselineArguments(
                        videoEncodingPlan: captionStageVideoEncodingPlan,
                        includeFastStart: false
                    )
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
                        let captionPrep = await self.prepareParakeetBurnInCaptions(
                            sourceURL: stagedBaseURL,
                            durationSeconds: clipDuration,
                            cachedTranscriptSegments: captionTranscriptSnapshot,
                            cachedTranscriptStartSeconds: config.clipStartSeconds,
                            cachedTranscriptEndSeconds: config.clipEndSeconds
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
                                    "-map", "0:v:0"
                                ]
                                burnArgs.append(contentsOf: videoEncodingArguments(for: finalVideoEncodingPlan))
                                burnArgs.append(contentsOf: [
                                    "-vf", MediaToolUtilities.subtitlesFilterArgument(path: prepared.srtURL.path, style: config.clipAdvancedCaptionStyle),
                                    "-map", "0:a:0?",
                                    "-c:a", "copy"
                                ])
                                if config.selectedClipFormat == .mp4 || config.selectedClipFormat == .mov {
                                    burnArgs.append(contentsOf: ["-movflags", "+faststart"])
                                }
                                burnArgs.append(destination.path)

                                encodeError = await self.runFFmpegProcessWithProgress(
                                    executableURL: ffmpegURL,
                                    arguments: burnArgs,
                                    durationSeconds: clipDuration,
                                    statusPrefix: "Encoding captioned clip",
                                    progressRange: 0.65...1.0
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
                    statusPrefix: config.isFullSourceConversion ? "Encoding video" : "Encoding advanced clip"
                )
            }

            await MainActor.run {
                guard self.activeClipExportRunToken == exportRunToken else { return }
                self.activeClipExportRunToken = nil
                self.exportTask = nil
                self.isExporting = false
                self.exportProgress = 0
                if self.exportCancellationRequested {
                    self.exportStatusText = "\(exportName) cancelled"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .cancelled
                    self.notifyCompletion("\(exportName.capitalized) Stopped", message: self.exportStatusText, outcome: .cancelled)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .cancelled, message: self.exportStatusText)
                    return
                }
                if let encodeError {
                    self.exportStatusText = "\(exportName) failed: \(encodeError)"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                    self.notifyCompletion("\(exportName.capitalized) Failed", message: self.exportStatusText, outcome: .failed)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .failed, message: self.exportStatusText)
                } else {
                    self.outputURL = destination
                    self.exportStatusText = "\(exportName) complete: \(destination.lastPathComponent)"
                    if config.clipAdvancedAddFadeInOut && !applyAudioFade {
                        self.uiMessage = "\(exportName) complete: \(destination.lastPathComponent). Audio fade was skipped for media under 2.0s."
                    } else {
                        self.uiMessage = self.exportStatusText
                    }
                    self.lastActivityState = .success
                    self.notifyCompletion("\(exportName.capitalized) Complete", message: self.uiMessage)
                    self.completeQueuedJobIfNeeded(queueJobID, status: .completed, message: self.exportStatusText, outputURL: destination)
                }
            }
        }
    }

    private struct BurnInCaptionPreparation {
        let srtURL: URL
        let tempDirectory: URL
    }

    private func prepareParakeetBurnInCaptions(
        sourceURL: URL,
        durationSeconds: Double,
        cachedTranscriptSegments: [TranscriptSegment]?,
        cachedTranscriptStartSeconds: Double,
        cachedTranscriptEndSeconds: Double
    ) async -> (preparation: BurnInCaptionPreparation?, error: String?) {
        guard findParakeetTranscriberExecutable() != nil,
              findParakeetModelDirectory() != nil else {
            return (nil, "Parakeet resources are not bundled. Rebuild the app with the Parakeet helper and model.")
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bvt-burnin-captions-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        } catch {
            return (nil, "Unable to create temporary caption directory: \(error.localizedDescription)")
        }

        let srtURL = tempDirectory.appendingPathComponent("caption-track.srt")
        let transcript: [TranscriptSegment]
        let sourceStart: Double
        let sourceEnd: Double
        if let cachedTranscriptSegments {
            transcript = cachedTranscriptSegments
            sourceStart = cachedTranscriptStartSeconds
            sourceEnd = cachedTranscriptEndSeconds
            exportProgress = max(exportProgress, 0.65)
            exportStatusText = "Formatting cached transcript for captions…"
        } else {
            let cancelFlag = exportCancelFlag
            let captureConsoleOutput = showActivityConsole
            let relay = TranscriptGenerationRelay(
                disableBatching: false,
                captureConsoleOutput: captureConsoleOutput,
                progressSink: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isExporting else { return }
                        let clamped = min(1.0, max(0.0, progress))
                        self.exportProgress = 0.50 + (clamped * 0.15)
                        self.exportStatusText = "Generating captions… \(Int((clamped * 100).rounded()))%"
                    }
                },
                segmentSink: { _ in },
                consoleSink: { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        self?.appendActivityConsoleChunk(chunk)
                    }
                },
                phaseSink: { [weak self] phase in
                    Task { @MainActor [weak self] in
                        guard let self, self.isExporting else { return }
                        self.exportStatusText = "Generating captions: \(phase)…"
                    }
                }
            )
            let result = await Task.detached(priority: .userInitiated) {
                transcribeAudioWithParakeet(
                    file: sourceURL,
                    shouldCancel: {
                        cancelFlag.isCancelled()
                    },
                    progressHandler: { progress in
                        relay.enqueueProgress(progress)
                    },
                    progressPhaseHandler: { phase in
                        relay.enqueuePhase(phase)
                    },
                    onConsoleOutput: { line, source in
                        relay.enqueueConsole(line: line, source: source)
                    }
                )
            }.value
            relay.flushNow()

            switch result {
            case .success(let generatedTranscript):
                transcript = generatedTranscript
                sourceStart = 0
                sourceEnd = durationSeconds
            case .failure(.cancelled):
                return (nil, "Cancelled")
            case .failure(.failed(let reason)):
                return (nil, "Parakeet transcription failed: \(reason)")
            }
        }

        let cues = makeBurnInCaptionCues(
            from: transcript,
            sourceStart: sourceStart,
            sourceEnd: sourceEnd
        )
        guard !cues.isEmpty else {
            return (nil, "Parakeet produced no timed caption cues.")
        }

        do {
            try burnInCaptionSRT(from: cues).write(to: srtURL, atomically: true, encoding: .utf8)
        } catch {
            return (nil, "Unable to write subtitle file: \(error.localizedDescription)")
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
