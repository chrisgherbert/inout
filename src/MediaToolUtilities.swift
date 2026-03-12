import Foundation

enum MediaToolUtilities {
    static func escapeSubtitlesFilterPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: ",", with: "\\,")
    }

    static func subtitlesFilterArgument(path: String, style: BurnInCaptionStyle) -> String {
        let escapedPath = escapeSubtitlesFilterPath(path)
        let escapedStyle = style.ffmpegForceStyle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "subtitles='\(escapedPath)':force_style='\(escapedStyle)'"
    }

    static func shellQuoted(_ argument: String) -> String {
        if argument.isEmpty { return "\"\"" }
        let requiresQuote = argument.contains { $0.isWhitespace || $0 == "\"" || $0 == "'" }
        if !requiresQuote { return argument }
        return "\"" + argument.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func formatProcessCommand(executableURL: URL, arguments: [String]) -> String {
        ([executableURL.path] + arguments).map(shellQuoted).joined(separator: " ")
    }

    static func uniqueURL(
        in directory: URL,
        preferredFileName: String,
        fileManager: FileManager = .default
    ) -> URL {
        let ext = (preferredFileName as NSString).pathExtension
        let baseName = (preferredFileName as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(preferredFileName)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(baseName)-\(index)" : "\(baseName)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(nextName)
            index += 1
        }
        return candidate
    }

    static func uniqueUnderscoreIndexedURL(
        in directory: URL,
        preferredFileName: String,
        fileManager: FileManager = .default
    ) -> URL {
        let ext = (preferredFileName as NSString).pathExtension
        let baseName = (preferredFileName as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(preferredFileName)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(baseName)_\(index)" : "\(baseName)_\(index).\(ext)"
            candidate = directory.appendingPathComponent(nextName)
            index += 1
        }
        return candidate
    }
}
