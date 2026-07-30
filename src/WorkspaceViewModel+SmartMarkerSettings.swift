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
            openAIConnectionSucceeded = false
            openAIConnectionStatusText = "API key removed."
        } catch {
            openAIConnectionSucceeded = false
            openAIConnectionStatusText = error.localizedDescription
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
}
