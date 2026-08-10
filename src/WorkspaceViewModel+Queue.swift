import Foundation
import InOutCore

@MainActor
extension WorkspaceViewModel {
    func beginDirectJobTracking(fileName: String, summary: String, subtitle: String? = nil) -> UUID {
        let id = UUID()
        let item = QueuedClipExport(
            id: id,
            createdAt: Date(),
            fileName: fileName,
            summary: summary,
            subtitle: subtitle,
            status: .running,
            message: nil
        )
        queuedJobs.append(item)
        activeQueuedJobID = id
        return id
    }

    func clipJobTitle(skipSaveDialog: Bool, mode: ClipEncodingMode) -> String {
        JobPresentationUtilities.clipJobTitle(skipSaveDialog: skipSaveDialog, mode: mode)
    }

    func clipJobSubtitle(
        mode: ClipEncodingMode,
        format: String,
        startSeconds: Double,
        endSeconds: Double
    ) -> String {
        JobPresentationUtilities.clipJobSubtitle(
            mode: mode,
            format: format,
            startSeconds: startSeconds,
            endSeconds: endSeconds
        )
    }

    func analysisJobSubtitle(black: Bool, badEdits: Bool, silence: Bool, profanity: Bool) -> String {
        JobPresentationUtilities.analysisJobSubtitle(black: black, badEdits: badEdits, silence: silence, profanity: profanity)
    }

    func analysisJobTitle(black: Bool, badEdits: Bool, silence: Bool, profanity: Bool) -> String {
        JobPresentationUtilities.analysisJobTitle(black: black, badEdits: badEdits, silence: silence, profanity: profanity)
    }

    func defaultClipExportFileName(
        for sourceURL: URL,
        config: QueuedClipExportConfig? = nil
    ) -> String {
        let config = config ?? queuedClipExportConfigSnapshot()
        if config.isFullSourceConversion {
            let outputExtension = config.clipEncodingMode == .audioOnly
                ? config.clipAudioOnlyFormat.fileExtension
                : config.selectedClipFormat.fileExtension
            return sourceURL.deletingPathExtension().lastPathComponent + "_converted." + outputExtension
        }
        return ClipExportUtilities.defaultClipExportFileName(
            ClipExportNamingInput(
                sourceName: sourceURL.deletingPathExtension().lastPathComponent,
                clipEncodingMode: config.clipEncodingMode,
                selectedClipFormat: config.selectedClipFormat,
                clipAudioOnlyFormat: config.clipAudioOnlyFormat,
                clipAdvancedVideoCodec: config.clipAdvancedVideoCodec,
                clipCompatibleMaxResolution: config.clipCompatibleMaxResolution,
                sourceResolution: sourceInfo?.resolution,
                clipStartSeconds: config.clipStartSeconds,
                clipEndSeconds: config.clipEndSeconds,
                advancedFilenameTemplate: advancedClipFilenameTemplate
            )
        )
    }

    func promptClipExportDestination(
        for sourceURL: URL,
        defaultName: String,
        config: QueuedClipExportConfig? = nil
    ) -> URL? {
        let config = config ?? queuedClipExportConfigSnapshot()
        let title: String
        if config.isFullSourceConversion {
            title = config.clipEncodingMode == .audioOnly ? "Export Audio" : "Export Video"
        } else {
            title = "Export Clip"
        }
        return ClipExportUtilities.promptClipExportDestination(
            defaultName: defaultName,
            contentType: config.clipEncodingMode == .audioOnly
                ? config.clipAudioOnlyFormat.contentType
                : config.selectedClipFormat.contentType,
            title: title
        )
    }

    func enqueueCurrentClipExport(skipSaveDialog: Bool = false) {
        guard canQueueClipExport, let sourceURL else { return }
        let destinationURL: URL?
        if skipSaveDialog {
            destinationURL = nil
        } else {
            let defaultName = defaultClipExportFileName(for: sourceURL)
            guard let chosenURL = promptClipExportDestination(for: sourceURL, defaultName: defaultName) else {
                uiMessage = "Save cancelled."
                return
            }
            destinationURL = chosenURL
        }
        let config = queuedClipExportConfigSnapshot(destinationURL: destinationURL)
        enqueueClipExport(config: config, skipSaveDialog: skipSaveDialog)
    }

    func startFullSourceExport(mode: ClipEncodingMode) {
        guard mode == .compressed || mode == .audioOnly,
              let sourceURL,
              sourceDurationSeconds > 0,
              !isGeneratingTranscript,
              (mode == .audioOnly ? hasAudioTrack : hasVideoTrack) else {
            uiMessage = "Unable to start conversion."
            return
        }

        let pendingConfig = queuedClipExportConfigSnapshot(
            startSeconds: 0,
            endSeconds: sourceDurationSeconds,
            encodingMode: mode,
            isFullSourceConversion: true
        )
        let defaultName = defaultClipExportFileName(for: sourceURL, config: pendingConfig)
        guard let destinationURL = promptClipExportDestination(
            for: sourceURL,
            defaultName: defaultName,
            config: pendingConfig
        ) else {
            uiMessage = "Save cancelled."
            return
        }
        let config = queuedClipExportConfigSnapshot(
            destinationURL: destinationURL,
            startSeconds: 0,
            endSeconds: sourceDurationSeconds,
            encodingMode: mode,
            isFullSourceConversion: true
        )

        if isAnalyzing || isExporting || isGeneratingTranscript {
            enqueueClipExport(config: config)
        } else {
            startClipExport(
                preselectedDestination: destinationURL,
                configOverride: config
            )
        }
    }

    func canRequestFullSourceExport(mode: ClipEncodingMode) -> Bool {
        sourceURL != nil &&
            sourceDurationSeconds > 0 &&
            !isGeneratingTranscript &&
            (mode == .audioOnly ? hasAudioTrack : hasVideoTrack)
    }

    private func enqueueClipExport(
        config: QueuedClipExportConfig,
        skipSaveDialog: Bool = false
    ) {
        guard let sourceURL else { return }
        let formatLabel = config.clipEncodingMode == .audioOnly ? config.clipAudioOnlyFormat.rawValue : config.selectedClipFormat.rawValue
        let summary = config.isFullSourceConversion
            ? (config.clipEncodingMode == .audioOnly ? "Audio Export" : "Video Export")
            : clipJobTitle(skipSaveDialog: skipSaveDialog, mode: config.clipEncodingMode)
        let subtitle = clipJobSubtitle(
            mode: config.clipEncodingMode,
            format: formatLabel,
            startSeconds: config.clipStartSeconds,
            endSeconds: config.clipEndSeconds
        )
        let item = QueuedClipExport(
            id: UUID(),
            createdAt: Date(),
            fileName: sourceURL.lastPathComponent,
            summary: summary,
            subtitle: subtitle,
            status: .queued,
            message: nil
        )
        queuedJobKinds[item.id] = .clip(skipSaveDialog: skipSaveDialog)
        queuedClipExportConfigs[item.id] = config
        queuedJobs.append(item)
        uiMessage = "Queued job (\(queuedJobs.count) pending)"
        startNextQueuedJobIfPossible()
    }

    func enqueueCurrentAnalysis() {
        guard canRequestAnalyze, let sourceURL else { return }
        let item = QueuedClipExport(
            id: UUID(),
            createdAt: Date(),
            fileName: sourceURL.lastPathComponent,
            summary: analysisJobTitle(
                black: analyzeBlackFrames,
                badEdits: analyzeBadEdits,
                silence: analyzeAudioSilence,
                profanity: analyzeProfanity
            ),
            subtitle: analysisJobSubtitle(
                black: analyzeBlackFrames,
                badEdits: analyzeBadEdits,
                silence: analyzeAudioSilence,
                profanity: analyzeProfanity
            ),
            status: .queued,
            message: nil
        )
        queuedJobKinds[item.id] = .analysis
        queuedAnalysisConfigs[item.id] = QueuedAnalysisConfig(
            analyzeBlackFrames: analyzeBlackFrames,
            analyzeBadEdits: analyzeBadEdits,
            analyzeAudioSilence: analyzeAudioSilence,
            analyzeProfanity: analyzeProfanity,
            silenceMinDurationSeconds: silenceMinDurationSeconds,
            profanityWordsText: profanityWordsText
        )
        queuedJobs.append(item)
        uiMessage = "Queued job (\(queuedJobs.count) pending)"
        startNextQueuedJobIfPossible()
    }

    func removeQueuedJob(_ id: UUID) {
        if activeQueuedJobID == id {
            stopCurrentActivity()
            return
        }
        queuedJobs.removeAll { $0.id == id }
        queuedJobKinds[id] = nil
        queuedClipExportConfigs[id] = nil
        queuedAnalysisConfigs[id] = nil
    }

    func retryQueuedJob(_ id: UUID) {
        guard let index = queuedJobs.firstIndex(where: { $0.id == id }) else { return }
        queuedJobs[index].status = .queued
        queuedJobs[index].message = nil
        queuedJobs[index].outputURL = nil
        startNextQueuedJobIfPossible()
    }

    func clearCompletedQueuedJobs() {
        let removableIDs = Set(
            queuedJobs
                .filter { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
                .map(\.id)
        )
        queuedJobs.removeAll { removableIDs.contains($0.id) }
        for id in removableIDs {
            queuedJobKinds[id] = nil
            queuedClipExportConfigs[id] = nil
            queuedAnalysisConfigs[id] = nil
        }
    }

    func queuedClipExportConfigSnapshot(
        destinationURL: URL? = nil,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        encodingMode: ClipEncodingMode? = nil,
        isFullSourceConversion: Bool = false
    ) -> QueuedClipExportConfig {
        QueuedClipExportConfig(
            clipStartSeconds: startSeconds ?? clipStartSeconds,
            clipEndSeconds: endSeconds ?? clipEndSeconds,
            clipEncodingMode: encodingMode ?? clipEncodingMode,
            selectedClipFormat: selectedClipFormat,
            clipAudioOnlyFormat: clipAudioOnlyFormat,
            clipAdvancedVideoCodec: clipAdvancedVideoCodec,
            clipCompatibleSpeedPreset: clipCompatibleSpeedPreset,
            clipCompatibleMaxResolution: clipCompatibleMaxResolution,
            clipFramingAspectRatio: clipFramingAspectRatio,
            clipFramingMode: clipFramingMode,
            clipFramingCropAlignment: clipFramingCropAlignment,
            sourceVideoDimensions: parsedMediaResolution(sourceInfo?.resolution),
            clipVideoBitrateMbps: clipVideoBitrateMbps,
            clipAudioBitrateKbps: clipAudioBitrateKbps,
            clipAdvancedBoostAudio: clipAdvancedBoostAudio,
            clipAdvancedBoostAmount: clipAdvancedBoostAmount,
            clipAdvancedAddFadeInOut: clipAdvancedAddFadeInOut,
            clipAdvancedBurnInCaptions: clipAdvancedBurnInCaptions,
            clipAdvancedCaptionStyle: clipAdvancedCaptionStyle,
            clipAudioOnlyBoostAudio: clipAudioOnlyBoostAudio,
            clipAudioOnlyAddFadeInOut: clipAudioOnlyAddFadeInOut,
            isFullSourceConversion: isFullSourceConversion,
            destinationURL: destinationURL
        )
    }

    func clearQueuedJobs() {
        queuedJobs.removeAll()
        queuedJobKinds.removeAll()
        queuedClipExportConfigs.removeAll()
        queuedAnalysisConfigs.removeAll()
        activeQueuedJobID = nil
    }

    func startNextQueuedJobIfPossible() {
        guard !isAnalyzing, !isExporting, !isGeneratingTranscript, activeQueuedJobID == nil else { return }
        guard let next = queuedJobs.first(where: { $0.status == .queued }),
              let kind = queuedJobKinds[next.id] else { return }
        if let index = queuedJobs.firstIndex(where: { $0.id == next.id }) {
            queuedJobs[index].status = .running
            queuedJobs[index].message = nil
        }
        activeQueuedJobID = next.id
        switch kind {
        case .clip(let skipSaveDialog):
            guard let config = queuedClipExportConfigs[next.id] else {
                completeQueuedJobIfNeeded(next.id, status: .failed, message: "Missing clip export config.")
                return
            }
            startClipExport(
                skipSaveDialog: skipSaveDialog,
                queueJobID: next.id,
                preselectedDestination: config.destinationURL,
                configOverride: config
            )
        case .analysis:
            guard let config = queuedAnalysisConfigs[next.id] else {
                completeQueuedJobIfNeeded(next.id, status: .failed, message: "Missing analysis config.")
                return
            }
            analyzeBlackFrames = config.analyzeBlackFrames
            analyzeBadEdits = config.analyzeBadEdits
            analyzeAudioSilence = config.analyzeAudioSilence
            analyzeProfanity = config.analyzeProfanity
            silenceMinDurationSeconds = config.silenceMinDurationSeconds
            profanityWordsText = config.profanityWordsText
            startAnalysis(queueJobID: next.id)
        }
    }

    func completeQueuedJobIfNeeded(_ queueJobID: UUID?, status: ClipExportQueueStatus, message: String? = nil, outputURL: URL? = nil) {
        let resolvedJobID = queueJobID ?? activeQueuedJobID
        guard let resolvedJobID else { return }
        if let index = queuedJobs.firstIndex(where: { $0.id == resolvedJobID }) {
            queuedJobs[index].status = status
            queuedJobs[index].message = message
            queuedJobs[index].outputURL = outputURL
        }
        activeQueuedJobID = nil
        DispatchQueue.main.async { [weak self] in
            self?.startNextQueuedJobIfPossible()
        }
    }
}
