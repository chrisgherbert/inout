import CryptoKit
import Foundation

struct DownloaderManifest: Codable {
    let version: String
    let sha256: String
    let sourceURL: String
    let installedAt: Date
    let channel: String
}

struct DownloaderRuntimeManifest: Codable {
    let version: String
    let sha256: String
    let sourceURL: String
    let installedAt: Date
}

struct YTDLPLaunchCommand {
    let executableURL: URL
    let preArguments: [String]
    let environment: [String: String]
    let source: String
}

enum DownloaderStatus: Equatable {
    case bundledFallback
    case externalCurrent(version: String)
    case missing
    case broken(String)

    var label: String {
        switch self {
        case .bundledFallback:
            return "Bundled Fallback"
        case .externalCurrent(let version):
            return "External (\(version))"
        case .missing:
            return "Missing"
        case .broken(let detail):
            return "Broken: \(detail)"
        }
    }
}

enum DownloaderManagerError: LocalizedError {
    case appSupportUnavailable
    case pythonRuntimeUnavailable
    case bundledFallbackUnavailable
    case runtimeAssetUnavailable
    case downloadFailed(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .appSupportUnavailable:
            return "Application Support folder is unavailable."
        case .pythonRuntimeUnavailable:
            return "Python runtime support is unavailable."
        case .bundledFallbackUnavailable:
            return "Bundled yt-dlp fallback is unavailable."
        case .runtimeAssetUnavailable:
            return "Downloader runtime asset is unavailable from the latest release."
        case .downloadFailed(let reason):
            return "Downloader update failed: \(reason)"
        case .validationFailed(let reason):
            return "Downloader validation failed: \(reason)"
        }
    }
}

final class DownloaderManager {
    static let shared = DownloaderManager()

    private let fileManager = FileManager.default
    private let session: URLSession
    private let officialYTDLPURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp")!
    private let repoOwner = "chrisgherbert"
    private let repoName = "inout"
    private let runtimeAssetName = "In-Out-python-runtime.tar.gz"
    private let runtimeSHAAssetName = "In-Out-python-runtime.tar.gz.sha256"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func currentStatus() -> DownloaderStatus {
        if let externalScriptURL,
           let command = externalLaunchCommand(for: externalScriptURL),
           let version = try? readVersion(using: command),
           let manifest = externalManifest(),
           manifest.version == version {
            return .externalCurrent(version: version)
        }

        if let fallback = bundledFallbackLaunchCommand(),
           (try? readVersion(using: fallback)) != nil {
            return .bundledFallback
        }

        if activePythonURL == nil {
            return .missing
        }

        if externalScriptURL != nil {
            return .broken("External downloader did not validate.")
        }

        if bundledYTDLPScriptURL != nil {
            return .broken("Bundled fallback downloader did not validate.")
        }

        return .missing
    }

    func pythonRuntimeAvailable() -> Bool {
        activePythonHomeURL != nil
    }

    func pythonRuntimeVersion() -> String? {
        if let bundled = bundledPythonHomeURL {
            return try? readPythonVersion(atHome: bundled)
        }
        if let installed = installedPythonHomeURL {
            return try? readPythonVersion(atHome: installed)
        }
        return nil
    }

    func activeLaunchCommand() -> YTDLPLaunchCommand? {
        if let externalScriptURL,
           let command = externalLaunchCommand(for: externalScriptURL),
           (try? readVersion(using: command)) != nil {
            return command
        }
        return bundledFallbackLaunchCommand()
    }

    func bundledFallbackLaunchCommand() -> YTDLPLaunchCommand? {
        guard let scriptURL = bundledYTDLPScriptURL,
              let pythonURL = activePythonURL,
              let pythonHome = activePythonHomeURL,
              fileManager.fileExists(atPath: scriptURL.path) else {
            return nil
        }

        return YTDLPLaunchCommand(
            executableURL: pythonURL,
            preArguments: ["-B", scriptURL.path],
            environment: pythonEnvironment(homeURL: pythonHome),
            source: "bundled"
        )
    }

    func externalManifest() -> DownloaderManifest? {
        guard let currentManifestURL,
              let data = try? Data(contentsOf: currentManifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DownloaderManifest.self, from: data)
    }

    func previousManifest() -> DownloaderManifest? {
        guard let previousManifestURL,
              let data = try? Data(contentsOf: previousManifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DownloaderManifest.self, from: data)
    }

    func runtimeManifest() -> DownloaderRuntimeManifest? {
        let manifestURL = runtimeManifestURL
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DownloaderRuntimeManifest.self, from: data)
    }

    var canRollbackToPrevious: Bool {
        previousManifest() != nil && (previousScriptURL?.path).map(fileManager.fileExists(atPath:)) == true
    }

    func installOrUpdateDownloader() async throws -> DownloaderManifest {
        let pythonHome = try await ensurePythonRuntimeReady(forceRefresh: false)
        guard let appSupportRoot else {
            throw DownloaderManagerError.appSupportUnavailable
        }

        try fileManager.createDirectory(at: appSupportRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: tmpDirectoryURL, withIntermediateDirectories: true)

        let tempDirectory = tmpDirectoryURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let downloadedScriptURL = tempDirectory.appendingPathComponent("yt-dlp")
        let (data, response) = try await session.data(from: officialYTDLPURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloaderManagerError.downloadFailed("Unexpected HTTP response.")
        }
        try data.write(to: downloadedScriptURL, options: .atomic)
        try setExecutablePermissions(at: downloadedScriptURL)

        let command = try externalLaunchCommand(for: downloadedScriptURL, pythonHome: pythonHome)
            .unwrap(or: DownloaderManagerError.validationFailed("Unable to create launch command."))
        let version = try readVersion(using: command)
        let sha = sha256Hex(for: data)

        let manifest = DownloaderManifest(
            version: version,
            sha256: sha,
            sourceURL: officialYTDLPURL.absoluteString,
            installedAt: Date(),
            channel: "external"
        )

        try replaceCurrentDownloader(withScriptAt: downloadedScriptURL, manifest: manifest)
        return manifest
    }

    func repairDownloader() async throws -> DownloaderManifest {
        _ = try await ensurePythonRuntimeReady(forceRefresh: true)
        return try await installOrUpdateDownloader()
    }

    func rollbackToPreviousDownloader() throws -> DownloaderManifest {
        guard let currentDirectoryURL,
              let previousDirectoryURL,
              fileManager.fileExists(atPath: previousDirectoryURL.path),
              let previousManifest = previousManifest() else {
            throw DownloaderManagerError.validationFailed("No previous downloader is available.")
        }

        let rollbackBackupURL = tmpDirectoryURL.appendingPathComponent("rollback-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: rollbackBackupURL)

        if fileManager.fileExists(atPath: currentDirectoryURL.path) {
            try fileManager.moveItem(at: currentDirectoryURL, to: rollbackBackupURL)
        }
        do {
            try fileManager.moveItem(at: previousDirectoryURL, to: currentDirectoryURL)
            if fileManager.fileExists(atPath: rollbackBackupURL.path) {
                try? fileManager.moveItem(at: rollbackBackupURL, to: previousDirectoryURL)
            }
            return previousManifest
        } catch {
            try? fileManager.removeItem(at: currentDirectoryURL)
            if fileManager.fileExists(atPath: rollbackBackupURL.path) {
                try? fileManager.moveItem(at: rollbackBackupURL, to: currentDirectoryURL)
            }
            throw error
        }
    }

    private func replaceCurrentDownloader(withScriptAt scriptURL: URL, manifest: DownloaderManifest) throws {
        guard let currentDirectoryURL,
              let previousDirectoryURL,
              let currentScriptURL,
              let currentManifestURL else {
            throw DownloaderManagerError.appSupportUnavailable
        }
        try? fileManager.removeItem(at: previousDirectoryURL)
        if fileManager.fileExists(atPath: currentDirectoryURL.path) {
            try fileManager.moveItem(at: currentDirectoryURL, to: previousDirectoryURL)
        }
        try fileManager.createDirectory(at: currentDirectoryURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: scriptURL, to: currentScriptURL)
        try setExecutablePermissions(at: currentScriptURL)

        let manifestData = try JSONEncoder.pretty.encode(manifest)
        try manifestData.write(to: currentManifestURL, options: .atomic)
    }

    private func latestRuntimeAsset() async throws -> RuntimeAssetInfo {
        let release = try await fetchLatestRelease()
        guard let archive = release.assets.first(where: { $0.name == runtimeAssetName }) else {
            throw DownloaderManagerError.runtimeAssetUnavailable
        }
        let checksumAsset = release.assets.first(where: { $0.name == runtimeSHAAssetName })
        return RuntimeAssetInfo(archiveURL: archive.browserDownloadURL, checksumURL: checksumAsset?.browserDownloadURL)
    }

    private func ensurePythonRuntimeReady(forceRefresh: Bool) async throws -> URL {
        if let bundledPythonHomeURL {
            return bundledPythonHomeURL
        }
        if !forceRefresh,
           let installed = installedPythonHomeURL,
           let runtimeManifest = runtimeManifest(),
           !runtimeManifest.version.isEmpty,
           fileManager.isExecutableFile(atPath: installed.appendingPathComponent("bin/python3").path) {
            return installed
        }

        guard let appSupportRoot else {
            throw DownloaderManagerError.appSupportUnavailable
        }
        try fileManager.createDirectory(at: appSupportRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: tmpDirectoryURL, withIntermediateDirectories: true)

        let asset = try await latestRuntimeAsset()
        let tempDirectory = tmpDirectoryURL.appendingPathComponent("runtime-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let archiveURL = tempDirectory.appendingPathComponent(runtimeAssetName)
        let (archiveData, archiveResponse) = try await session.data(from: asset.archiveURL)
        guard let http = archiveResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloaderManagerError.downloadFailed("Unexpected Python runtime response.")
        }
        try archiveData.write(to: archiveURL, options: .atomic)

        if let checksumURL = asset.checksumURL {
            let (checksumData, checksumResponse) = try await session.data(from: checksumURL)
            guard let http = checksumResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DownloaderManagerError.downloadFailed("Unexpected Python runtime checksum response.")
            }
            let expectedSHA = parseSHA256(from: checksumData)
            let actualSHA = sha256Hex(for: archiveData)
            guard expectedSHA == actualSHA else {
                throw DownloaderManagerError.validationFailed("Python runtime checksum mismatch.")
            }
        }

        let extractDirectory = tempDirectory.appendingPathComponent("extract", isDirectory: true)
        try fileManager.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
        let extractProcess = Process()
        extractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        extractProcess.arguments = ["-xzf", archiveURL.path, "-C", extractDirectory.path]
        let extractError = Pipe()
        extractProcess.standardError = extractError
        try extractProcess.run()
        extractProcess.waitUntilExit()
        guard extractProcess.terminationStatus == 0 else {
            let errorText = String(decoding: extractError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw DownloaderManagerError.validationFailed(
                errorText.isEmpty ? "Failed to extract Python runtime." : errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let extractedRoot = extractDirectory.appendingPathComponent("PythonRuntime", isDirectory: true)
        let extractedHome = extractedRoot.appendingPathComponent("current", isDirectory: true)
        let extractedPython = extractedHome.appendingPathComponent("bin/python3")
        guard fileManager.isExecutableFile(atPath: extractedPython.path) else {
            throw DownloaderManagerError.validationFailed("Downloaded Python runtime is missing python3.")
        }

        let version = try readPythonVersion(atHome: extractedHome)
        let manifest = DownloaderRuntimeManifest(
            version: version,
            sha256: sha256Hex(for: archiveData),
            sourceURL: asset.archiveURL.absoluteString,
            installedAt: Date()
        )

        try? fileManager.removeItem(at: runtimeRootDirectoryURL)
        try fileManager.moveItem(at: extractedRoot, to: runtimeRootDirectoryURL)
        let manifestData = try JSONEncoder.pretty.encode(manifest)
        try manifestData.write(to: runtimeManifestURL, options: .atomic)
        return runtimeCurrentDirectoryURL
    }

    private func readVersion(using command: YTDLPLaunchCommand) throws -> String {
        let output = try runProcess(
            executableURL: command.executableURL,
            arguments: command.preArguments + ["--version"],
            environment: command.environment
        )
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw DownloaderManagerError.validationFailed("Empty version response.")
        }
        return version
    }

    private func readPythonVersion(atHome homeURL: URL) throws -> String {
        let pythonURL = homeURL.appendingPathComponent("bin/python3")
        let output = try runProcess(
            executableURL: pythonURL,
            arguments: ["-c", "import sys; print('.'.join(map(str, sys.version_info[:3])))"],
            environment: pythonEnvironment(homeURL: homeURL)
        )
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw DownloaderManagerError.validationFailed("Empty Python version response.")
        }
        return version
    }

    private func runProcess(executableURL: URL, arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if !environment.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                merged[key] = value
            }
            process.environment = merged
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw DownloaderManagerError.validationFailed(
                err.isEmpty ? "Process exited with status \(process.terminationStatus)" : err.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return out
    }

    private func externalLaunchCommand(for scriptURL: URL, pythonHome: URL? = nil) -> YTDLPLaunchCommand? {
        guard let pythonHome = pythonHome ?? activePythonHomeURL,
              let pythonURL = pythonExecutableURL(forHome: pythonHome),
              fileManager.fileExists(atPath: scriptURL.path) else {
            return nil
        }
        return YTDLPLaunchCommand(
            executableURL: pythonURL,
            preArguments: ["-B", scriptURL.path],
            environment: pythonEnvironment(homeURL: pythonHome),
            source: "external"
        )
    }

    private func pythonEnvironment(homeURL: URL) -> [String: String] {
        [
            "PYTHONHOME": homeURL.path,
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONPYCACHEPREFIX": tmpPycacheRoot.path
        ]
    }

    private func pythonExecutableURL(forHome homeURL: URL) -> URL? {
        let url = homeURL.appendingPathComponent("bin/python3")
        return fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }

    private func setExecutablePermissions(at url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func sha256Hex(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func parseSHA256(from data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
    }

    private var appSupportRoot: URL? {
        guard let base = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        return base.appendingPathComponent("In-Out", isDirectory: true).appendingPathComponent("Downloader", isDirectory: true)
    }

    private var currentDirectoryURL: URL? {
        appSupportRoot?.appendingPathComponent("current", isDirectory: true)
    }

    private var previousDirectoryURL: URL? {
        appSupportRoot?.appendingPathComponent("previous", isDirectory: true)
    }

    private var tmpDirectoryURL: URL {
        (appSupportRoot ?? fileManager.temporaryDirectory).appendingPathComponent("tmp", isDirectory: true)
    }

    private var currentScriptURL: URL? {
        currentDirectoryURL?.appendingPathComponent("yt-dlp")
    }

    private var currentManifestURL: URL? {
        currentDirectoryURL?.appendingPathComponent("manifest.json")
    }

    private var previousManifestURL: URL? {
        previousDirectoryURL?.appendingPathComponent("manifest.json")
    }

    private var externalScriptURL: URL? {
        guard let url = currentScriptURL else { return nil }
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private var previousScriptURL: URL? {
        previousDirectoryURL?.appendingPathComponent("yt-dlp")
    }

    private var bundledYTDLPScriptURL: URL? {
        if let script = Bundle.main.url(forResource: "yt-dlp", withExtension: "py"),
           fileManager.fileExists(atPath: script.path) {
            return script
        }
        if let script = Bundle.main.url(forResource: "yt-dlp", withExtension: nil),
           fileManager.fileExists(atPath: script.path) {
            return script
        }
        return nil
    }

    private var bundledPythonHomeURL: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("PythonRuntime/current", isDirectory: true)
        if let bundled, fileManager.isExecutableFile(atPath: bundled.appendingPathComponent("bin/python3").path) {
            return bundled
        }
        return nil
    }

    private var installedPythonHomeURL: URL? {
        let current = runtimeCurrentDirectoryURL
        let python = current.appendingPathComponent("bin/python3")
        return fileManager.isExecutableFile(atPath: python.path) ? current : nil
    }

    private var activePythonHomeURL: URL? {
        bundledPythonHomeURL ?? installedPythonHomeURL
    }

    private var activePythonURL: URL? {
        guard let home = activePythonHomeURL else { return nil }
        return pythonExecutableURL(forHome: home)
    }

    private var tmpPycacheRoot: URL {
        fileManager.temporaryDirectory.appendingPathComponent("inout-python-pyc", isDirectory: true)
    }

    private var runtimeRootDirectoryURL: URL {
        (appSupportRoot ?? fileManager.temporaryDirectory).appendingPathComponent("PythonRuntime", isDirectory: true)
    }

    private var runtimeCurrentDirectoryURL: URL {
        runtimeRootDirectoryURL.appendingPathComponent("current", isDirectory: true)
    }

    private var runtimeManifestURL: URL {
        runtimeRootDirectoryURL.appendingPathComponent("manifest.json")
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            throw DownloaderManagerError.downloadFailed("Invalid release URL.")
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("InOutDownloaderManager", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DownloaderManagerError.downloadFailed("GitHub latest release lookup failed.")
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

private struct RuntimeAssetInfo {
    let archiveURL: URL
    let checksumURL: URL?
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

    let assets: [Asset]
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
