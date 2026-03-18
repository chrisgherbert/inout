import AppKit
import Foundation

enum URLDownloadUtilities {
    static func normalizedDownloadURL(from raw: String) -> URL? {
        if let parsed = URL(string: raw),
           let scheme = parsed.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            return parsed
        }
        if let parsed = URL(string: "https://" + raw),
           let scheme = parsed.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            return parsed
        }
        return nil
    }

    static func ytDLPFormatArguments(for preset: URLDownloadPreset) -> [String] {
        switch preset {
        case .compatibleBest:
            return [
                "-S", "res,codec:h264,aext:m4a",
                "-f", "bestvideo[ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4][vcodec^=avc1]/best[ext=mp4]"
            ]
        case .compatible1080:
            return [
                "-S", "res,codec:h264,aext:m4a",
                "-f", "bestvideo[height<=1080][ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=1080][ext=mp4][vcodec^=avc1]/best[height<=1080][ext=mp4]"
            ]
        case .compatible720:
            return [
                "-S", "res,codec:h264,aext:m4a",
                "-f", "bestvideo[height<=720][ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=720][ext=mp4][vcodec^=avc1]/best[height<=720][ext=mp4]"
            ]
        case .bestAnyToMP4:
            return [
                "-f", "bestvideo*+bestaudio/best"
            ]
        case .audioOnly:
            return [
                "-f", "bestaudio/best",
                "--extract-audio",
                "--audio-format", "mp3"
            ]
        }
    }

    static func ytDLPAuthenticationArguments(
        authenticationMode: URLDownloadAuthenticationMode,
        browserCookiesSource: URLDownloadBrowserCookiesSource
    ) -> [String] {
        switch authenticationMode {
        case .none:
            return []
        case .browserCookies:
            return ["--cookies-from-browser", browserCookiesSource.ytDLPArgument]
        }
    }

    static func defaultDownloadDirectoryURL(fileManager: FileManager = .default) -> URL? {
        if let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return downloads
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    static func defaultDownloadFileNameTemplate(for preset: URLDownloadPreset, sourceURL: URL) -> String {
        let host = (sourceURL.host ?? "download")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        // yt-dlp will expand title/id placeholders. Prefixing with host keeps source context.
        return "\(host) - %(title)s [%(id)s].\(preset.outputExtension)"
    }

    static func promptURLDownloadDestination(
        for preset: URLDownloadPreset,
        sourceURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = false
        panel.allowedFileTypes = [preset.outputExtension]
        panel.nameFieldStringValue = defaultDownloadFileNameTemplate(for: preset, sourceURL: sourceURL)
        panel.title = "Save Downloaded Media"
        panel.prompt = "Save"
        if let defaultDirectory = defaultDownloadDirectoryURL(fileManager: fileManager) {
            panel.directoryURL = defaultDirectory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if url.pathExtension.isEmpty {
            return url.appendingPathExtension(preset.outputExtension)
        }
        return url
    }

    static func resolveURLDownloadDestination(
        for preset: URLDownloadPreset,
        sourceURL: URL,
        saveMode: URLDownloadSaveLocationMode,
        customFolderPath: String?,
        fileManager: FileManager = .default
    ) -> URL? {
        switch saveMode {
        case .askEachTime:
            return promptURLDownloadDestination(for: preset, sourceURL: sourceURL, fileManager: fileManager)
        case .downloadsFolder:
            guard let folder = defaultDownloadDirectoryURL(fileManager: fileManager) else { return nil }
            return MediaToolUtilities.uniqueUnderscoreIndexedURL(
                in: folder,
                preferredFileName: defaultDownloadFileNameTemplate(for: preset, sourceURL: sourceURL),
                fileManager: fileManager
            )
        case .customFolder:
            guard let customFolderPath, !customFolderPath.isEmpty else { return nil }
            let folder = URL(fileURLWithPath: customFolderPath)
            guard fileManager.fileExists(atPath: folder.path) else { return nil }
            return MediaToolUtilities.uniqueUnderscoreIndexedURL(
                in: folder,
                preferredFileName: defaultDownloadFileNameTemplate(for: preset, sourceURL: sourceURL),
                fileManager: fileManager
            )
        }
    }
}
