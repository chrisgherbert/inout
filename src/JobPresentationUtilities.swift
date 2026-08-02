import Foundation

enum JobPresentationUtilities {
    static func clipJobTitle(skipSaveDialog: Bool, mode: ClipEncodingMode) -> String {
        let prefix = skipSaveDialog ? "Quick " : ""
        switch mode {
        case .fast:
            return "\(prefix)Clip Export - Fast Copy"
        case .compressed:
            return "\(prefix)Clip Export - Advanced Encode"
        case .audioOnly:
            return "\(prefix)Clip Export - Audio Only"
        }
    }

    static func clipJobSubtitle(
        mode: ClipEncodingMode,
        format: String,
        startSeconds: Double,
        endSeconds: Double
    ) -> String {
        "\(mode.rawValue) • \(format) • \(formatSeconds(startSeconds)) → \(formatSeconds(endSeconds))"
    }

    static func analysisJobSubtitle(black: Bool, badEdits: Bool, silence: Bool, profanity: Bool) -> String {
        var detectors: [String] = []
        if black { detectors.append("Black Frames") }
        if badEdits { detectors.append("Possible Bad Edits") }
        if silence { detectors.append("Silence") }
        if profanity { detectors.append("Profanity") }
        if detectors.isEmpty { return "No detectors selected" }
        return detectors.joined(separator: " + ")
    }

    static func analysisJobTitle(black: Bool, badEdits: Bool, silence: Bool, profanity: Bool) -> String {
        let enabledCount = [black, badEdits, silence, profanity].filter { $0 }.count
        if enabledCount <= 1 {
            if black { return "Analyze - Black Frames" }
            if badEdits { return "Analyze - Possible Bad Edits" }
            if silence { return "Analyze - Silence Gaps" }
            if profanity { return "Analyze - Profanity" }
            return "Analyze Media"
        }
        return "Analyze Media"
    }
}
