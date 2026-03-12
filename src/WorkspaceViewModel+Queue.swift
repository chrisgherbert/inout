import Foundation

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

    func audioExportJobTitle(format: AudioFormat) -> String {
        JobPresentationUtilities.audioExportJobTitle(format: format)
    }

    func audioExportJobSubtitle(bitrateKbps: Int) -> String {
        JobPresentationUtilities.audioExportJobSubtitle(bitrateKbps: bitrateKbps)
    }

    func analysisJobSubtitle(black: Bool, silence: Bool, profanity: Bool) -> String {
        JobPresentationUtilities.analysisJobSubtitle(black: black, silence: silence, profanity: profanity)
    }

    func analysisJobTitle(black: Bool, silence: Bool, profanity: Bool) -> String {
        JobPresentationUtilities.analysisJobTitle(black: black, silence: silence, profanity: profanity)
    }

    func defaultAudioExportFileName(for sourceURL: URL) -> String {
        ClipExportUtilities.defaultAudioExportFileName(sourceURL: sourceURL, selectedAudioFormat: selectedAudioFormat)
    }

    func promptAudioExportDestination(for sourceURL: URL) -> URL? {
        ClipExportUtilities.promptAudioExportDestination(sourceURL: sourceURL, selectedAudioFormat: selectedAudioFormat)
    }

    func defaultClipExportFileName(for sourceURL: URL) -> String {
        ClipExportUtilities.defaultClipExportFileName(
            ClipExportNamingInput(
                sourceName: sourceURL.deletingPathExtension().lastPathComponent,
                clipEncodingMode: clipEncodingMode,
                selectedClipFormat: selectedClipFormat,
                clipAudioOnlyFormat: clipAudioOnlyFormat,
                clipAdvancedVideoCodec: clipAdvancedVideoCodec,
                clipCompatibleMaxResolution: clipCompatibleMaxResolution,
                sourceResolution: sourceInfo?.resolution,
                clipStartSeconds: clipStartSeconds,
                clipEndSeconds: clipEndSeconds,
                advancedFilenameTemplate: advancedClipFilenameTemplate
            )
        )
    }

    func promptClipExportDestination(for sourceURL: URL, defaultName: String) -> URL? {
        ClipExportUtilities.promptClipExportDestination(
            defaultName: defaultName,
            contentType: clipEncodingMode == .audioOnly ? clipAudioOnlyFormat.contentType : selectedClipFormat.contentType
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
        let formatLabel = config.clipEncodingMode == .audioOnly ? config.clipAudioOnlyFormat.rawValue : config.selectedClipFormat.rawValue
        let summary = clipJobTitle(skipSaveDialog: skipSaveDialog, mode: config.clipEncodingMode)
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

    func enqueueCurrentAudioExport() {
        guard canRequestAudioExport, let sourceURL else { return }
        guard let destinationURL = promptAudioExportDestination(for: sourceURL) else {
            uiMessage = "Save cancelled."
            return
        }
        let item = QueuedClipExport(
            id: UUID(),
            createdAt: Date(),
            fileName: sourceURL.lastPathComponent,
            summary: audioExportJobTitle(format: selectedAudioFormat),
            subtitle: audioExportJobSubtitle(bitrateKbps: exportAudioBitrateKbps),
            status: .queued,
            message: nil
        )
        queuedJobKinds[item.id] = .audioExport
        queuedAudioExportConfigs[item.id] = QueuedAudioExportConfig(
            selectedAudioFormat: selectedAudioFormat,
            exportAudioBitrateKbps: exportAudioBitrateKbps,
            destinationURL: destinationURL
        )
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
                silence: analyzeAudioSilence,
                profanity: analyzeProfanity
            ),
            subtitle: analysisJobSubtitle(
                black: analyzeBlackFrames,
                silence: analyzeAudioSilence,
                profanity: analyzeProfanity
            ),
            status: .queued,
            message: nil
        )
        queuedJobKinds[item.id] = .analysis
        queuedAnalysisConfigs[item.id] = QueuedAnalysisConfig(
            analyzeBlackFrames: analyzeBlackFrames,
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
        queuedAudioExportConfigs[id] = nil
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
            queuedAudioExportConfigs[id] = nil
            queuedAnalysisConfigs[id] = nil
        }
    }

    func queuedClipExportConfigSnapshot(destinationURL: URL? = nil) -> QueuedClipExportConfig {
        QueuedClipExportConfig(
            clipStartSeconds: clipStartSeconds,
            clipEndSeconds: clipEndSeconds,
            clipEncodingMode: clipEncodingMode,
            selectedClipFormat: selectedClipFormat,
            clipAudioOnlyFormat: clipAudioOnlyFormat,
            clipAdvancedVideoCodec: clipAdvancedVideoCodec,
            clipCompatibleSpeedPreset: clipCompatibleSpeedPreset,
            clipCompatibleMaxResolution: clipCompatibleMaxResolution,
            clipVideoBitrateMbps: clipVideoBitrateMbps,
            clipAudioBitrateKbps: clipAudioBitrateKbps,
            clipAdvancedBoostAudio: clipAdvancedBoostAudio,
            clipAdvancedBoostAmount: clipAdvancedBoostAmount,
            clipAdvancedAddFadeInOut: clipAdvancedAddFadeInOut,
            clipAdvancedBurnInCaptions: clipAdvancedBurnInCaptions,
            clipAdvancedCaptionStyle: clipAdvancedCaptionStyle,
            clipAudioOnlyBoostAudio: clipAudioOnlyBoostAudio,
            clipAudioOnlyAddFadeInOut: clipAudioOnlyAddFadeInOut,
            destinationURL: destinationURL
        )
    }

    func applyQueuedClipExportConfig(_ config: QueuedClipExportConfig) {
        clipStartSeconds = config.clipStartSeconds
        clipEndSeconds = config.clipEndSeconds
        clipEncodingMode = config.clipEncodingMode
        selectedClipFormat = config.selectedClipFormat
        clipAudioOnlyFormat = config.clipAudioOnlyFormat
        clipAdvancedVideoCodec = config.clipAdvancedVideoCodec
        clipCompatibleSpeedPreset = config.clipCompatibleSpeedPreset
        clipCompatibleMaxResolution = config.clipCompatibleMaxResolution
        clipVideoBitrateMbps = config.clipVideoBitrateMbps
        clipAudioBitrateKbps = config.clipAudioBitrateKbps
        clipAdvancedBoostAudio = config.clipAdvancedBoostAudio
        clipAdvancedBoostAmount = config.clipAdvancedBoostAmount
        clipAdvancedAddFadeInOut = config.clipAdvancedAddFadeInOut
        clipAdvancedBurnInCaptions = config.clipAdvancedBurnInCaptions
        clipAdvancedCaptionStyle = config.clipAdvancedCaptionStyle
        clipAudioOnlyBoostAudio = config.clipAudioOnlyBoostAudio
        clipAudioOnlyAddFadeInOut = config.clipAudioOnlyAddFadeInOut
        syncClipTextFields()
    }

    func clearQueuedJobs() {
        queuedJobs.removeAll()
        queuedJobKinds.removeAll()
        queuedClipExportConfigs.removeAll()
        queuedAudioExportConfigs.removeAll()
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
            applyQueuedClipExportConfig(config)
            startClipExport(skipSaveDialog: skipSaveDialog, queueJobID: next.id, preselectedDestination: config.destinationURL)
        case .audioExport:
            guard let config = queuedAudioExportConfigs[next.id] else {
                completeQueuedJobIfNeeded(next.id, status: .failed, message: "Missing audio export config.")
                return
            }
            selectedAudioFormat = config.selectedAudioFormat
            exportAudioBitrateKbps = config.exportAudioBitrateKbps
            startExport(queueJobID: next.id, preselectedDestination: config.destinationURL)
        case .analysis:
            guard let config = queuedAnalysisConfigs[next.id] else {
                completeQueuedJobIfNeeded(next.id, status: .failed, message: "Missing analysis config.")
                return
            }
            analyzeBlackFrames = config.analyzeBlackFrames
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
