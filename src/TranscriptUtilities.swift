import AppKit
import Foundation
import UniformTypeIdentifiers

enum TranscriptUtilities {
    static func timedPlainText(from segments: [TranscriptSegment]) -> String {
        segments
            .map(\.formatted)
            .joined(separator: "\n")
    }

    static func plainTextWithoutTimecodes(from segments: [TranscriptSegment]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func srtTimestamp(_ seconds: Double) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        let hours = Int(safe / 3600)
        let minutes = Int((safe.truncatingRemainder(dividingBy: 3600)) / 60)
        let wholeSeconds = Int(safe.truncatingRemainder(dividingBy: 60))
        let millis = Int((safe - floor(safe)) * 1000.0)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, wholeSeconds, millis)
    }

    static func srt(from segments: [TranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            let text = segment.text.replacingOccurrences(of: "\r\n", with: "\n")
            return """
            \(index + 1)
            \(srtTimestamp(segment.start)) --> \(srtTimestamp(segment.end))
            \(text)
            """
        }
        .joined(separator: "\n\n") + "\n"
    }

    static func content(from segments: [TranscriptSegment], format: TranscriptExportFormat) -> String {
        switch format {
        case .plainText:
            return plainTextWithoutTimecodes(from: segments)
        case .timedText:
            return timedPlainText(from: segments)
        case .srt:
            return srt(from: segments)
        }
    }

    static func makeExportPanel(defaultName: String, format: TranscriptExportFormat) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        panel.message = "Export \(format.menuTitle)"
        panel.prompt = "Export"
        return panel
    }
}
