import AppKit
import Foundation
import UniformTypeIdentifiers

enum TranscriptUtilities {
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

    static func webVTT(from segments: [TranscriptSegment]) -> String {
        let cues = segments.map { segment in
            """
            \(webVTTTimestamp(segment.start)) --> \(webVTTTimestamp(segment.end))
            \(segment.text.replacingOccurrences(of: "\r\n", with: "\n"))
            """
        }
        return "WEBVTT\n\n" + cues.joined(separator: "\n\n") + "\n"
    }

    static func content(
        from segments: [TranscriptSegment],
        format: TranscriptExportFormat,
        layout: TranscriptExportLayout,
        timecodeStyle: TranscriptExportTimecodeStyle
    ) -> String {
        switch format {
        case .text, .markdown:
            return readableContent(
                from: segments,
                format: format,
                layout: layout,
                timecodeStyle: timecodeStyle
            )
        case .csv:
            return csv(from: segments)
        case .json:
            return json(from: segments)
        case .srt:
            return srt(from: segments)
        case .webVTT:
            return webVTT(from: segments)
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

    private static func readableContent(
        from segments: [TranscriptSegment],
        format: TranscriptExportFormat,
        layout: TranscriptExportLayout,
        timecodeStyle: TranscriptExportTimecodeStyle
    ) -> String {
        let displayMode: TranscriptDisplayMode = layout == .paragraphs ? .paragraphs : .compact
        let rows = makeTranscriptDisplayRows(from: segments, mode: displayMode)
        let effectiveTimecodes: TranscriptExportTimecodeStyle = layout == .continuousText
            ? .none
            : timecodeStyle

        if layout == .continuousText {
            return normalizedContinuousText(rows.map(\.text).joined(separator: " "))
        }

        let separator = layout == .paragraphs ? "\n\n" : "\n"
        return rows.map { row in
            let timecode = readableTimecode(
                start: row.start,
                end: row.end,
                style: effectiveTimecodes
            )
            guard !timecode.isEmpty else { return row.text }
            if format == .markdown {
                return layout == .paragraphs
                    ? "**\(timecode)**\n\n\(row.text)"
                    : "**\(timecode)**  \n\(row.text)"
            }
            return layout == .paragraphs
                ? "\(timecode)\n\(row.text)"
                : "\(timecode)  \(row.text)"
        }
        .joined(separator: separator)
    }

    private static func readableTimecode(
        start: Double,
        end: Double,
        style: TranscriptExportTimecodeStyle
    ) -> String {
        switch style {
        case .none:
            return ""
        case .start:
            return exportTimestamp(start)
        case .startAndEnd:
            return "\(exportTimestamp(start)) --> \(exportTimestamp(end))"
        }
    }

    private static func csv(from segments: [TranscriptSegment]) -> String {
        let header = "Start,End,Duration (seconds),Text"
        let rows = segments.map { segment in
            [
                exportTimestamp(segment.start),
                exportTimestamp(segment.end),
                String(format: "%.3f", segment.duration),
                segment.text
            ]
            .map(csvField)
            .joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private static func json(from segments: [TranscriptSegment]) -> String {
        let payload: [String: Any] = [
            "format_version": 1,
            "segments": segments.map { segment in
                [
                    "start": segment.start,
                    "end": segment.end,
                    "duration": segment.duration,
                    "text": segment.text
                ] as [String: Any]
            }
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let result = String(data: data, encoding: .utf8) else {
            return "{}\n"
        }
        return result + "\n"
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func normalizedContinuousText(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func exportTimestamp(_ seconds: Double) -> String {
        timestamp(seconds, millisecondSeparator: ".")
    }

    private static func webVTTTimestamp(_ seconds: Double) -> String {
        timestamp(seconds, millisecondSeparator: ".")
    }

    private static func timestamp(_ seconds: Double, millisecondSeparator: Character) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        let totalMilliseconds = Int((safe * 1000).rounded(.down))
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let wholeSeconds = (totalMilliseconds / 1_000) % 60
        let milliseconds = totalMilliseconds % 1_000
        let wholeTime = String(format: "%02d:%02d:%02d", hours, minutes, wholeSeconds)
        return "\(wholeTime)\(millisecondSeparator)\(String(format: "%03d", milliseconds))"
    }
}
