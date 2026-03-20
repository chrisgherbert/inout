import Foundation
import AppKit
import AVFoundation

extension WorkspaceViewModel {
    func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a media file"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.urls.first {
            setSource(url)
        }
    }

    func presentURLImportSheet() {
        guard canRequestURLDownload else {
            uiMessage = "Finish current task before downloading."
            return
        }
        guard ytDLPAvailable else {
            ensureManagedDownloaderReadyIfNeeded { [weak self] in
                self?.isURLImportSheetPresented = true
            }
            return
        }
        ensureManagedDownloaderReadyIfNeeded { [weak self] in
            self?.isURLImportSheetPresented = true
        }
    }

    // Backwards compatibility for existing call sites.
    func importSourceFromURL() {
        presentURLImportSheet()
    }

    func startURLImport(
        urlText: String,
        preset: URLDownloadPreset,
        saveMode: URLDownloadSaveLocationMode,
        customFolderPath: String?,
        authenticationMode: URLDownloadAuthenticationMode,
        browserCookiesSource: URLDownloadBrowserCookiesSource
    ) {
        guard canRequestURLDownload else {
            uiMessage = "Finish current task before downloading."
            return
        }
        guard let ytDLPLaunch = resolveYTDLPLaunch() else {
            uiMessage = "Downloader support is required to import from URL."
            return
        }
        guard let normalized = URLDownloadUtilities.normalizedDownloadURL(from: urlText) else {
            uiMessage = "Invalid URL. Please use an http(s) link."
            return
        }

        urlDownloadPreset = preset
        urlDownloadSaveLocationMode = saveMode
        if let customFolderPath {
            customURLDownloadDirectoryPath = customFolderPath
        }
        urlDownloadAuthenticationMode = authenticationMode
        urlDownloadBrowserCookiesSource = browserCookiesSource

        if preset.requiresTranscodeWarning && !confirmTranscodeDownloadWarning() {
            uiMessage = "Download cancelled."
            return
        }

        guard let destinationURL = URLDownloadUtilities.resolveURLDownloadDestination(
            for: preset,
            sourceURL: normalized,
            saveMode: saveMode,
            customFolderPath: customFolderPath
        ) else {
            uiMessage = "Unable to resolve download destination."
            return
        }

        isExporting = true
        lastActivityState = .running
        exportCancellationRequested = false
        exportProgress = 0
        clearActivityConsole()
        appendActivityConsole("URL download started", source: "yt-dlp")
        exportStatusText = "Preparing download…"
        uiMessage = "Downloading media from URL…"

        exportTask = Task { [weak self] in
            guard let self else { return }
            let ffmpegURL = self.findFFmpegExecutable()
            let ffmpegDirectory = ffmpegURL?.deletingLastPathComponent().path
            let shouldSplitTranscodeStages = preset == .bestAnyToMP4
            var temporaryStageDirectory: URL?
            defer {
                if let temporaryStageDirectory {
                    try? FileManager.default.removeItem(at: temporaryStageDirectory)
                }
            }

            let (downloadedPath, errorText): (String?, String?)
            if shouldSplitTranscodeStages {
                let tempRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("inout-url-download-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                temporaryStageDirectory = tempRoot

                let downloadTemplateURL = tempRoot.appendingPathComponent("downloaded.%(ext)s")
                let stagedArgs = [
                    "--no-playlist",
                    "--newline",
                    "--progress",
                    "--progress-template", "download:%(progress._percent_str)s",
                    "--print", "after_move:%(filepath)s",
                    "-o", downloadTemplateURL.path
                ] + URLDownloadUtilities.ytDLPFormatArguments(for: preset)
                  + URLDownloadUtilities.ytDLPAuthenticationArguments(
                    authenticationMode: authenticationMode,
                    browserCookiesSource: browserCookiesSource
                  )
                  + (ffmpegDirectory.map { ["--ffmpeg-location", $0] } ?? [])
                  + [normalized.absoluteString]

                let staged = await self.runYTDLPProcessWithProgress(
                    executableURL: ytDLPLaunch.executableURL,
                    preArguments: ytDLPLaunch.preArguments,
                    environment: ytDLPLaunch.environment,
                    arguments: stagedArgs,
                    statusPrefix: "Downloading source",
                    progressRange: 0.0...0.6
                )
                downloadedPath = staged.downloadedPath
                errorText = staged.error
            } else {
                let args = [
                    "--no-playlist",
                    "--newline",
                    "--progress",
                    "--progress-template", "download:%(progress._percent_str)s",
                    "--print", "after_move:%(filepath)s",
                    "-o", destinationURL.path
                ] + URLDownloadUtilities.ytDLPFormatArguments(for: preset)
                  + URLDownloadUtilities.ytDLPAuthenticationArguments(
                    authenticationMode: authenticationMode,
                    browserCookiesSource: browserCookiesSource
                  )
                  + (ffmpegDirectory.map { ["--ffmpeg-location", $0] } ?? [])
                  + [normalized.absoluteString]

                let direct = await self.runYTDLPProcessWithProgress(
                    executableURL: ytDLPLaunch.executableURL,
                    preArguments: ytDLPLaunch.preArguments,
                    environment: ytDLPLaunch.environment,
                    arguments: args,
                    statusPrefix: "Downloading media",
                    progressRange: 0.0...1.0
                )
                downloadedPath = direct.downloadedPath
                errorText = direct.error
            }

            await MainActor.run {
                if self.exportCancellationRequested {
                    self.exportTask = nil
                    self.activeProcess = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    self.exportStatusText = "Download cancelled"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .cancelled
                    return
                }
            }

            if let errorText {
                await MainActor.run {
                    self.exportTask = nil
                    self.activeProcess = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    self.exportStatusText = "Download failed: \(errorText)"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                }
                return
            }

            guard let downloadedPath, FileManager.default.fileExists(atPath: downloadedPath) else {
                await MainActor.run {
                    self.exportTask = nil
                    self.activeProcess = nil
                    self.isExporting = false
                    self.exportProgress = 0
                    self.exportStatusText = "Download failed: yt-dlp did not return an output file path."
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .failed
                }
                return
            }

            var finalURL = URL(fileURLWithPath: downloadedPath)

            if shouldSplitTranscodeStages {
                guard let ffmpegURL else {
                    await MainActor.run {
                        self.exportTask = nil
                        self.activeProcess = nil
                        self.isExporting = false
                        self.exportProgress = 0
                        self.exportStatusText = "Download failed: ffmpeg is required for this mode."
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                    }
                    return
                }

                let stagedAsset = AVURLAsset(url: finalURL)
                var stagedDurationSeconds: Double = 0
                if #available(macOS 13.0, *) {
                    if let loadedDuration = try? await stagedAsset.load(.duration) {
                        let seconds = CMTimeGetSeconds(loadedDuration)
                        if seconds.isFinite && seconds > 0.001 {
                            stagedDurationSeconds = seconds
                        }
                    }
                }
                if stagedDurationSeconds <= 0.001 {
                    let fallbackDirect = CMTimeGetSeconds(stagedAsset.duration)
                    if fallbackDirect.isFinite && fallbackDirect > 0.001 {
                        stagedDurationSeconds = fallbackDirect
                    }
                }
                if stagedDurationSeconds <= 0.001 {
                    let probed = loadSourceMediaInfo(for: finalURL).durationSeconds ?? 0
                    if probed.isFinite && probed > 0.001 {
                        stagedDurationSeconds = probed
                    }
                }
                let stagedInfo = loadSourceMediaInfo(for: finalURL)
                if stagedDurationSeconds <= 0.001 {
                    // Last-resort guard: avoid tiny denominator causing immediate 100%.
                    stagedDurationSeconds = 600.0
                }
                let duration = max(1.0, stagedDurationSeconds)
                let sourceVideoBps = stagedInfo.videoBitrateBps ?? sourceInfo?.videoBitrateBps ?? 0
                let targetVideoBps: Int = {
                    if sourceVideoBps > 0 {
                        let scaled = Int((sourceVideoBps * 0.80).rounded())
                        return min(max(2_500_000, scaled), 14_000_000)
                    }
                    return 6_000_000
                }()
                let targetAudioKbps = 160
                await MainActor.run {
                    self.appendActivityConsole("Hardware transcoding for compatibility (VideoToolbox)", source: "ffmpeg")
                    self.exportStatusText = "Transcoding for compatibility (hardware)…"
                    self.exportProgress = max(self.exportProgress, 0.61)
                }

                try? FileManager.default.removeItem(at: destinationURL)
                let hardwareArgs = [
                    "-y",
                    "-hide_banner",
                    "-loglevel", "error",
                    "-i", finalURL.path,
                    "-map", "0:v:0?",
                    "-c:v", "h264_videotoolbox",
                    "-b:v", "\(targetVideoBps)",
                    "-maxrate", "\(targetVideoBps)",
                    "-bufsize", "\(targetVideoBps * 2)",
                    "-pix_fmt", "yuv420p",
                    "-profile:v", "high",
                    "-map", "0:a:0?",
                    "-c:a", "aac",
                    "-b:a", "\(targetAudioKbps)k",
                    "-movflags", "+faststart",
                    destinationURL.path
                ]
                var transcodeError = await self.runFFmpegProcessWithProgress(
                    executableURL: ffmpegURL,
                    arguments: hardwareArgs,
                    durationSeconds: duration,
                    statusPrefix: "Hardware transcoding",
                    progressRange: 0.6...1.0
                )

                if transcodeError != nil {
                    await MainActor.run {
                        self.appendActivityConsole("Hardware encoder unavailable; falling back to software x264.", source: "ffmpeg")
                        self.exportStatusText = "Hardware unavailable, using software fallback…"
                        self.exportProgress = max(self.exportProgress, 0.65)
                    }
                    let softwareArgs = [
                        "-y",
                        "-hide_banner",
                        "-loglevel", "error",
                        "-i", finalURL.path,
                        "-map", "0:v:0?",
                        "-c:v", "libx264",
                        "-preset", "veryfast",
                        "-crf", "21",
                        "-pix_fmt", "yuv420p",
                        "-map", "0:a:0?",
                        "-c:a", "aac",
                        "-b:a", "\(targetAudioKbps)k",
                        "-movflags", "+faststart",
                        destinationURL.path
                    ]
                    transcodeError = await self.runFFmpegProcessWithProgress(
                        executableURL: ffmpegURL,
                        arguments: softwareArgs,
                        durationSeconds: duration,
                        statusPrefix: "Software fallback transcoding",
                        progressRange: 0.6...1.0
                    )
                }

                if let transcodeError {
                    await MainActor.run {
                        self.exportTask = nil
                        self.activeProcess = nil
                        self.isExporting = false
                        self.exportProgress = 0
                        self.exportStatusText = "Transcode failed: \(transcodeError)"
                        self.uiMessage = self.exportStatusText
                        self.lastActivityState = .failed
                    }
                    return
                }
                finalURL = destinationURL
            }

            await MainActor.run {
                self.exportTask = nil
                self.activeProcess = nil
                self.isExporting = false
                self.exportProgress = 0

                if self.exportCancellationRequested {
                    self.exportStatusText = "Download cancelled"
                    self.uiMessage = self.exportStatusText
                    self.lastActivityState = .cancelled
                    return
                }

                self.setSource(finalURL)
                self.outputURL = finalURL
                let stageLabel = shouldSplitTranscodeStages ? "Download + transcode complete" : "Download complete"
                self.exportStatusText = "\(stageLabel): \(finalURL.lastPathComponent)"
                self.uiMessage = self.exportStatusText
                self.lastActivityState = .success
            }
        }
    }

    private func confirmTranscodeDownloadWarning() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This Download May Require Transcoding"
        alert.informativeText = "Best Available can require conversion to MP4, which may be slower and use more CPU."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func chooseCustomURLDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.urls.first {
            customURLDownloadDirectoryPath = url.path
        }
    }

    func setSource(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if PlayheadBenchmarkConfig.shared.enabled {
            PlayheadDiagnostics.shared.writeProgress(stage: "set_source_begin", scenario: nil)
        }

        if (isAnalyzing || isExporting) && sourceURL?.path != url.path {
            guard confirmReplaceSourceDuringActiveJob(newURL: url) else { return }
        }

        if isAnalyzing || isExporting {
            stopCurrentActivity()
        }

        waveformCache.removeAll(keepingCapacity: false)
        waveformCacheOrder.removeAll(keepingCapacity: false)
        timelineThumbnailStripCache.removeAll(keepingCapacity: false)
        timelineThumbnailStripCacheOrder.removeAll(keepingCapacity: false)
        clearQueuedJobs()

        sourceURL = url
        sourceSessionID = UUID()
        analysis = FileAnalysis(fileURL: url)
        sourceInfo = loadSourceMediaInfo(for: url)
        transcriptSegments = []
        hasCachedTranscript = false
        transcriptStatusText = hasAudioTrack ? "No transcript generated yet." : "No audio track available for transcript."
        isGeneratingTranscript = false
        clipEncodingMode = hasVideoTrack ? defaultClipEncodingMode : .audioOnly
        applySuggestedClipBitrateFromSource()
        outputURL = nil
        uiMessage = "Loaded \(url.lastPathComponent)"
        wasCancelled = false
        analyzeProgress = 0
        exportProgress = 0
        captureTimelineMarkers = []
        highlightedCaptureTimelineMarkerID = nil
        highlightedClipBoundary = nil
        clipPlayheadSeconds = 0
        clearActivityConsole()
        resetClipRange()
        if PlayheadBenchmarkConfig.shared.enabled {
            PlayheadDiagnostics.shared.writeProgress(stage: "set_source_complete", scenario: nil)
        }
    }

    private func confirmReplaceSourceDuringActiveJob(newURL: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace Current File?"
        let activeTask = isAnalyzing ? "analysis" : "export"
        alert.informativeText = "A \(activeTask) is currently running. Replacing the file will stop the current job and load “\(newURL.lastPathComponent)”."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func clearSource() {
        if isAnalyzing || isExporting {
            stopCurrentActivity()
        }
        sourceURL = nil
        sourceSessionID = UUID()
        analysis = nil
        sourceInfo = nil
        transcriptSegments = []
        hasCachedTranscript = false
        transcriptStatusText = "No transcript generated yet."
        isGeneratingTranscript = false
        waveformCache.removeAll(keepingCapacity: false)
        waveformCacheOrder.removeAll(keepingCapacity: false)
        timelineThumbnailStripCache.removeAll(keepingCapacity: false)
        timelineThumbnailStripCacheOrder.removeAll(keepingCapacity: false)
        clearQueuedJobs()
        outputURL = nil
        captureTimelineMarkers = []
        highlightedCaptureTimelineMarkerID = nil
        highlightedClipBoundary = nil
        clipPlayheadSeconds = 0
        clearActivityConsole()
        uiMessage = "Ready"
        resetClipRange()
    }
}
