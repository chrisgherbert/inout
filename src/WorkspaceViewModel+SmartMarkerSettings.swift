import Foundation

extension WorkspaceViewModel {
    func saveOpenAIAPIKey(_ value: String) -> Bool {
        do {
            try SecureCredentialStore.setValue(
                value,
                for: SmartMarkerPreferences.openAIKeychainAccount
            )
            openAIAPIKeyConfigured = true
            openAIConnectionSucceeded = true
            openAIConnectionStatusText = "API key saved securely in Keychain."
            refreshOpenAIModels()
            return true
        } catch {
            openAIConnectionSucceeded = false
            openAIConnectionStatusText = error.localizedDescription
            return false
        }
    }

    func removeOpenAIAPIKey() {
        do {
            try SecureCredentialStore.removeValue(
                for: SmartMarkerPreferences.openAIKeychainAccount
            )
            openAIAPIKeyConfigured = false
            openAIAvailableModels = []
            openAIModelCatalogStatusText = ""
            SmartMarkerPreferences.clearOpenAIModelCatalog()
            openAIConnectionSucceeded = false
            openAIConnectionStatusText = "API key removed."
        } catch {
            openAIConnectionSucceeded = false
            openAIConnectionStatusText = error.localizedDescription
        }
    }

    func loadOpenAIModelsIfNeeded() {
        guard openAIAPIKeyConfigured else { return }
        if openAIAvailableModels.isEmpty ||
            SmartMarkerPreferences.openAIModelCatalogNeedsRefresh {
            refreshOpenAIModels()
        }
    }

    func refreshOpenAIModels() {
        guard !isLoadingOpenAIModels else { return }
        guard let key = SecureCredentialStore.value(
            for: SmartMarkerPreferences.openAIKeychainAccount
        ) else {
            openAIModelCatalogStatusText = "Save an API key to load models."
            return
        }

        isLoadingOpenAIModels = true
        openAIModelCatalogStatusText = "Loading models..."
        let selectedModel = openAISmartMarkerModel
        Task { [weak self] in
            guard let self else { return }
            do {
                let ids = try await OpenAIResponsesClient(
                    apiKey: key,
                    model: selectedModel
                ).listModels()
                guard !Task.isCancelled else { return }
                let options = SmartMarkerOpenAIModelCatalog.options(from: ids)
                self.openAIAvailableModels = options
                SmartMarkerPreferences.cacheOpenAIModelIDs(options.map(\.id))
                self.openAIModelCatalogStatusText = options.isEmpty
                    ? "No compatible text models were found."
                    : "Available models updated."
            } catch {
                guard !Task.isCancelled else { return }
                self.openAIModelCatalogStatusText = error.localizedDescription
            }
            self.isLoadingOpenAIModels = false
        }
    }

    func testOpenAIConnection() {
        guard !isTestingOpenAIConnection else { return }
        guard let key = SecureCredentialStore.value(
            for: SmartMarkerPreferences.openAIKeychainAccount
        ) else {
            openAIConnectionSucceeded = false
            openAIConnectionStatusText = "Add and save an API key first."
            return
        }

        isTestingOpenAIConnection = true
        openAIConnectionSucceeded = false
        openAIConnectionStatusText = "Checking OpenAI access..."
        let model = openAISmartMarkerModel
        Task { [weak self] in
            guard let self else { return }
            do {
                try await OpenAIResponsesClient(apiKey: key, model: model).testConnection()
                guard !Task.isCancelled else { return }
                self.openAIConnectionSucceeded = true
                self.openAIConnectionStatusText = "Connected. \(SmartMarkerPreferences.openAIModel) is available."
            } catch {
                guard !Task.isCancelled else { return }
                self.openAIConnectionSucceeded = false
                self.openAIConnectionStatusText = error.localizedDescription
            }
            self.isTestingOpenAIConnection = false
        }
    }

    func saveClaudeAPIKey(_ value: String) -> Bool {
        do {
            try SecureCredentialStore.setValue(
                value,
                for: SmartMarkerPreferences.claudeKeychainAccount
            )
            claudeAPIKeyConfigured = true
            claudeConnectionSucceeded = true
            claudeConnectionStatusText = "API key saved securely in Keychain."
            refreshClaudeModels()
            return true
        } catch {
            claudeConnectionSucceeded = false
            claudeConnectionStatusText = error.localizedDescription
            return false
        }
    }

    func removeClaudeAPIKey() {
        do {
            try SecureCredentialStore.removeValue(
                for: SmartMarkerPreferences.claudeKeychainAccount
            )
            claudeAPIKeyConfigured = false
            claudeAvailableModels = []
            claudeModelCatalogStatusText = ""
            SmartMarkerPreferences.clearClaudeModelCatalog()
            claudeConnectionSucceeded = false
            claudeConnectionStatusText = "API key removed."
        } catch {
            claudeConnectionSucceeded = false
            claudeConnectionStatusText = error.localizedDescription
        }
    }

    func loadClaudeModelsIfNeeded() {
        guard claudeAPIKeyConfigured else { return }
        if claudeAvailableModels.isEmpty ||
            SmartMarkerPreferences.claudeModelCatalogNeedsRefresh {
            refreshClaudeModels()
        }
    }

    func refreshClaudeModels() {
        guard !isLoadingClaudeModels else { return }
        guard let key = SecureCredentialStore.value(
            for: SmartMarkerPreferences.claudeKeychainAccount
        ) else {
            claudeModelCatalogStatusText = "Save an API key to load models."
            return
        }

        isLoadingClaudeModels = true
        claudeModelCatalogStatusText = "Loading models..."
        let selectedModel = claudeSmartMarkerModel
        Task { [weak self] in
            guard let self else { return }
            do {
                let ids = try await ClaudeMessagesClient(
                    apiKey: key,
                    model: selectedModel
                ).listModels()
                guard !Task.isCancelled else { return }
                let options = SmartMarkerClaudeModelCatalog.options(from: ids)
                self.claudeAvailableModels = options
                SmartMarkerPreferences.cacheClaudeModelIDs(options.map(\.id))
                self.claudeModelCatalogStatusText = options.isEmpty
                    ? "No compatible Claude models were found."
                    : "Available models updated."
            } catch {
                guard !Task.isCancelled else { return }
                self.claudeModelCatalogStatusText = error.localizedDescription
            }
            self.isLoadingClaudeModels = false
        }
    }

    func testClaudeConnection() {
        guard !isTestingClaudeConnection else { return }
        guard let key = SecureCredentialStore.value(
            for: SmartMarkerPreferences.claudeKeychainAccount
        ) else {
            claudeConnectionSucceeded = false
            claudeConnectionStatusText = "Add and save an API key first."
            return
        }
        isTestingClaudeConnection = true
        claudeConnectionSucceeded = false
        claudeConnectionStatusText = "Checking Anthropic access..."
        let selectedModel = claudeSmartMarkerModel
        Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await ClaudeMessagesClient(
                    apiKey: key,
                    model: selectedModel
                ).listModels()
                guard !Task.isCancelled else { return }
                guard models.contains(selectedModel) else {
                    throw SmartMarkerProviderError.unavailable(
                        "\(selectedModel) is not available to this API key."
                    )
                }
                self.claudeConnectionSucceeded = true
                self.claudeConnectionStatusText = "Connected. \(selectedModel) is available."
            } catch {
                guard !Task.isCancelled else { return }
                self.claudeConnectionSucceeded = false
                self.claudeConnectionStatusText = error.localizedDescription
            }
            self.isTestingClaudeConnection = false
        }
    }

    func saveGeminiAPIKey(_ value: String) -> Bool {
        do {
            try SecureCredentialStore.setValue(
                value,
                for: SmartMarkerPreferences.geminiKeychainAccount
            )
            geminiAPIKeyConfigured = true
            geminiConnectionSucceeded = true
            geminiConnectionStatusText = "API key saved securely in Keychain."
            refreshGeminiModels()
            return true
        } catch {
            geminiConnectionSucceeded = false
            geminiConnectionStatusText = error.localizedDescription
            return false
        }
    }

    func removeGeminiAPIKey() {
        do {
            try SecureCredentialStore.removeValue(
                for: SmartMarkerPreferences.geminiKeychainAccount
            )
            geminiAPIKeyConfigured = false
            geminiAvailableModels = []
            geminiModelCatalogStatusText = ""
            SmartMarkerPreferences.clearGeminiModelCatalog()
            geminiConnectionSucceeded = false
            geminiConnectionStatusText = "API key removed."
        } catch {
            geminiConnectionSucceeded = false
            geminiConnectionStatusText = error.localizedDescription
        }
    }

    func loadGeminiModelsIfNeeded() {
        guard geminiAPIKeyConfigured else { return }
        if geminiAvailableModels.isEmpty ||
            SmartMarkerPreferences.geminiModelCatalogNeedsRefresh {
            refreshGeminiModels()
        }
    }

    func refreshGeminiModels() {
        guard !isLoadingGeminiModels else { return }
        guard let key = SecureCredentialStore.value(
            for: SmartMarkerPreferences.geminiKeychainAccount
        ) else {
            geminiModelCatalogStatusText = "Save an API key to load models."
            return
        }

        isLoadingGeminiModels = true
        geminiModelCatalogStatusText = "Loading models..."
        let selectedModel = geminiSmartMarkerModel
        Task { [weak self] in
            guard let self else { return }
            do {
                let ids = try await GeminiGenerateContentClient(
                    apiKey: key,
                    model: selectedModel
                ).listModels()
                guard !Task.isCancelled else { return }
                let options = SmartMarkerGeminiModelCatalog.options(from: ids)
                self.geminiAvailableModels = options
                SmartMarkerPreferences.cacheGeminiModelIDs(options.map(\.id))
                self.geminiModelCatalogStatusText = options.isEmpty
                    ? "No compatible Gemini models were found."
                    : "Available models updated."
            } catch {
                guard !Task.isCancelled else { return }
                self.geminiModelCatalogStatusText = error.localizedDescription
            }
            self.isLoadingGeminiModels = false
        }
    }

    func testGeminiConnection() {
        guard !isTestingGeminiConnection else { return }
        guard let key = SecureCredentialStore.value(
            for: SmartMarkerPreferences.geminiKeychainAccount
        ) else {
            geminiConnectionSucceeded = false
            geminiConnectionStatusText = "Add and save an API key first."
            return
        }
        isTestingGeminiConnection = true
        geminiConnectionSucceeded = false
        geminiConnectionStatusText = "Checking Gemini access..."
        let selectedModel = geminiSmartMarkerModel
        Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await GeminiGenerateContentClient(
                    apiKey: key,
                    model: selectedModel
                ).listModels()
                guard !Task.isCancelled else { return }
                guard models.contains(selectedModel) else {
                    throw SmartMarkerProviderError.unavailable(
                        "\(selectedModel) is not available to this API key."
                    )
                }
                self.geminiConnectionSucceeded = true
                self.geminiConnectionStatusText = "Connected. \(selectedModel) is available."
            } catch {
                guard !Task.isCancelled else { return }
                self.geminiConnectionSucceeded = false
                self.geminiConnectionStatusText = error.localizedDescription
            }
            self.isTestingGeminiConnection = false
        }
    }
}
