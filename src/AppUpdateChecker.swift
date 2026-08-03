import Sparkle

@MainActor
final class AppUpdateChecker {
    static let shared = AppUpdateChecker()

    private let updaterController: SPUStandardUpdaterController

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func start() {
        // Accessing the singleton retains the controller for the app's lifetime.
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
