import Foundation

@MainActor
extension WorkspaceViewModel {
    func refreshExternalToolAvailabilityCache() {
        cachedFFmpegAvailable = (findFFmpegExecutable() != nil)
        cachedFFprobeAvailable = (findFFprobeExecutable() != nil)
        cachedYTDLPAvailable = downloaderManager.pythonRuntimeAvailable()
            && (downloaderManager.activeLaunchCommand() != nil)
        cachedWhisperCLIAvailable = (findWhisperExecutable() != nil)
        cachedWhisperModelAvailable = (findWhisperModel() != nil)
        cachedWhisperAvailable = (cachedWhisperCLIAvailable && cachedWhisperModelAvailable)
    }

    func recheckSetupChecks() {
        refreshExternalToolAvailabilityCache()
        refreshDownloaderStatus()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshDownloaderStatus(validating: true)
            self.refreshExternalToolAvailabilityCache()
        }
    }

    func refreshDownloaderStatus(validating: Bool = false) {
        let status = validating ? downloaderManager.validatedStatus() : downloaderManager.quickStatus()
        downloaderCanRollback = downloaderManager.canRollbackToPrevious
        downloaderPreviousVersionText = downloaderManager.previousManifest()?.version ?? ""
        managedPythonVersionText = downloaderManager.pythonRuntimeVersion() ?? "Unavailable"
        downloaderStatusText = status.label
        switch status {
        case .bundledFallback:
            if let fallback = downloaderManager.bundledFallbackLaunchCommand(),
               let version = try? downloaderManagerVersion(for: fallback) {
                downloaderVersionText = version
            } else {
                downloaderVersionText = "Bundled fallback"
            }
            downloaderLastErrorText = ""
        case .externalCurrent(let version):
            downloaderVersionText = version
            downloaderLastErrorText = ""
        case .missing:
            downloaderVersionText = "Unavailable"
            downloaderLastErrorText = ""
        case .broken(let detail):
            downloaderVersionText = "Unavailable"
            downloaderLastErrorText = detail
        }
    }

    func updateDownloaderSupport() {
        guard !isUpdatingDownloader else { return }
        isUpdatingDownloader = true
        downloaderLastErrorText = ""
        downloaderActionStatusText = "Checking for downloader updates…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let manifest = try await self.downloaderManager.installOrUpdateDownloader()
                self.uiMessage = "Downloader updated to \(manifest.version)."
                self.downloaderActionStatusText = "Downloader updated to \(manifest.version)."
            } catch {
                self.downloaderLastErrorText = error.localizedDescription
                self.uiMessage = error.localizedDescription
                self.downloaderActionStatusText = "Downloader update failed."
            }
            self.isUpdatingDownloader = false
            self.refreshExternalToolAvailabilityCache()
            self.refreshDownloaderStatus(validating: true)
        }
    }

    func repairDownloaderSupport() {
        guard !isUpdatingDownloader else { return }
        isUpdatingDownloader = true
        downloaderLastErrorText = ""
        downloaderActionStatusText = "Repairing downloader support…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let manifest = try await self.downloaderManager.repairDownloader()
                self.uiMessage = "Downloader repaired (\(manifest.version))."
                self.downloaderActionStatusText = "Downloader repaired (\(manifest.version))."
            } catch {
                self.downloaderLastErrorText = error.localizedDescription
                self.uiMessage = error.localizedDescription
                self.downloaderActionStatusText = "Downloader repair failed."
            }
            self.isUpdatingDownloader = false
            self.refreshExternalToolAvailabilityCache()
            self.refreshDownloaderStatus(validating: true)
        }
    }

    func rollbackDownloaderSupport() {
        guard !isUpdatingDownloader else { return }
        isUpdatingDownloader = true
        downloaderLastErrorText = ""
        downloaderActionStatusText = "Rolling back downloader…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let manifest = try self.downloaderManager.rollbackToPreviousDownloader()
                self.uiMessage = "Downloader rolled back to \(manifest.version)."
                self.downloaderActionStatusText = "Downloader rolled back to \(manifest.version)."
            } catch {
                self.downloaderLastErrorText = error.localizedDescription
                self.uiMessage = error.localizedDescription
                self.downloaderActionStatusText = "Downloader rollback failed."
            }
            self.isUpdatingDownloader = false
            self.refreshExternalToolAvailabilityCache()
            self.refreshDownloaderStatus(validating: true)
        }
    }

    func ensureManagedDownloaderReadyIfNeeded(then action: @escaping @MainActor () -> Void) {
        switch downloaderManager.validatedStatus() {
        case .externalCurrent:
            action()
        case .bundledFallback, .missing, .broken:
            guard !isUpdatingDownloader else {
                uiMessage = "Preparing downloader support…"
                downloaderActionStatusText = "Preparing downloader support…"
                return
            }
            isUpdatingDownloader = true
            downloaderLastErrorText = ""
            uiMessage = "Preparing downloader support…"
            downloaderActionStatusText = "Preparing downloader support…"
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.isUpdatingDownloader = false
                    self.refreshExternalToolAvailabilityCache()
                    self.refreshDownloaderStatus(validating: true)
                }
                do {
                    let manifest = try await self.downloaderManager.installOrUpdateDownloader()
                    self.uiMessage = "Downloader ready (\(manifest.version))."
                    self.downloaderActionStatusText = "Downloader ready (\(manifest.version))."
                } catch {
                    self.downloaderLastErrorText = error.localizedDescription
                    if self.ytDLPAvailable {
                        self.uiMessage = "Using bundled fallback downloader."
                        self.downloaderActionStatusText = "Using bundled fallback downloader."
                    } else {
                        self.uiMessage = error.localizedDescription
                        self.downloaderActionStatusText = "Downloader preparation failed."
                        return
                    }
                }
                action()
            }
        }
    }

    private func downloaderManagerVersion(for command: YTDLPLaunchCommand) throws -> String {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.preArguments + ["--version"]
        if !command.environment.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in command.environment {
                merged[key] = value
            }
            process.environment = merged
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Unknown" : text
    }
}
