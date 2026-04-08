import AppKit
import Foundation

@MainActor
final class AppUpdateChecker {
    static let shared = AppUpdateChecker()

    private let repoOwner = "chrisgherbert"
    private let repoName = "inout"
    private let skippedVersionDefaultsKey = "updateChecker.skippedVersion"
    private var isChecking = false
    private var hasPerformedInitialCheck = false

    private init() {}

    func performInitialCheckIfNeeded() {
        guard !hasPerformedInitialCheck else { return }
        hasPerformedInitialCheck = true
        checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool = true) {
        guard !isChecking else { return }
        isChecking = true

        Task {
            defer {
                Task { @MainActor in
                    self.isChecking = false
                }
            }

            do {
                let release = try await fetchLatestRelease()
                let currentVersion = appVersion()
                let skippedVersion = UserDefaults.standard.string(forKey: skippedVersionDefaultsKey)

                if isVersion(release.version, newerThan: currentVersion) {
                    if !userInitiated, skippedVersion == release.version {
                        return
                    }
                    await MainActor.run {
                        presentUpdateAvailableAlert(latest: release.version, current: currentVersion, url: release.downloadURL)
                    }
                } else if userInitiated {
                    await MainActor.run {
                        presentUpToDateAlert(current: currentVersion)
                    }
                }
            } catch {
                if userInitiated {
                    await MainActor.run {
                        presentUpdateCheckFailedAlert(error)
                    }
                }
            }
        }
    }

    private func appVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = parsedVersionComponents(from: lhs)
        let b = parsedVersionComponents(from: rhs)
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv {
                return av > bv
            }
        }
        return false
    }

    private func parsedVersionComponents(from raw: String) -> [Int] {
        let withoutPrefix = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let core = withoutPrefix
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .split(separator: "+", maxSplits: 1, omittingEmptySubsequences: true)
            .first ?? Substring(withoutPrefix)

        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    private func presentUpdateAvailableAlert(latest: String, current: String, url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update Available"
        alert.informativeText = "In/Out \(latest) is available. You’re currently on \(current)."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            UserDefaults.standard.removeObject(forKey: skippedVersionDefaultsKey)
            NSWorkspace.shared.open(url)
        } else if response == .alertSecondButtonReturn {
            UserDefaults.standard.set(latest, forKey: skippedVersionDefaultsKey)
        }
    }

    private func presentUpToDateAlert(current: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "You’re Up to Date"
        alert.informativeText = "In/Out \(current) is the latest available version."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentUpdateCheckFailedAlert(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update Check Failed"
        alert.informativeText = "Couldn’t check for updates right now.\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func fetchLatestRelease() async throws -> LatestRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            throw UpdateCheckError.invalidURL
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("InOutAppUpdater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.badServerResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw UpdateCheckError.httpStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = decoded.tagName.replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let downloadURL =
            decoded.assets.first(where: { $0.name.hasSuffix(".dmg") && $0.name.contains("In-Out-macOS") })?.browserDownloadURL
            ?? decoded.assets.first(where: { $0.name.hasSuffix(".dmg") })?.browserDownloadURL
            ?? decoded.assets.first(where: { $0.name.hasSuffix(".zip") && $0.name.contains("In-Out-macOS") })?.browserDownloadURL
            ?? decoded.assets.first(where: { $0.name.hasSuffix(".zip") })?.browserDownloadURL
            ?? decoded.htmlURL

        return LatestRelease(version: version, downloadURL: downloadURL)
    }
}

private struct LatestRelease {
    let version: String
    let downloadURL: URL
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private enum UpdateCheckError: LocalizedError {
    case invalidURL
    case badServerResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid update URL."
        case .badServerResponse:
            return "Unexpected server response."
        case .httpStatus(let code):
            return "Server returned HTTP \(code)."
        }
    }
}
