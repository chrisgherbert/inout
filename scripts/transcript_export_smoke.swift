import Combine
import Foundation
import InOutCore

final class WorkspaceViewModel: ObservableObject {}

func formatSeconds(_ value: Double) -> String {
    String(format: "%.3f", value)
}

final class ClipTranscriptPlaybackPresentation {
    var activeRowID: UUID?
    var activeRowDidChange: ((UUID?) -> Void)?
    var displayedPlaybackSeconds: Double = 0
}

final class PlayheadDiagnostics {
    static let shared = PlayheadDiagnostics()
    func noteTranscriptRowLayout() {}
    func noteTranscriptCellCreated() {}
    func noteTranscriptRowViewCreated() {}
    func noteTranscriptTableUpdate(duration: Double) {}
    func noteTranscriptFollow(duration: Double) {}
    func noteModelWrite(_ value: String) {}
}

@main
struct TranscriptExportSmokeTest {
    static func main() throws {
        let segments = [
            TranscriptSegment(
                start: 1.25,
                end: 2.5,
                text: "Hello, \"world\".",
                timedWords: [
                    TranscriptWordTiming(word: "Hello,", start: 1.25, end: 1.7),
                    TranscriptWordTiming(word: "\"world\".", start: 1.75, end: 2.5)
                ]
            ),
            TranscriptSegment(
                start: 5,
                end: 6.75,
                text: "The next paragraph has a comma, too.",
                timedWords: [
                    TranscriptWordTiming(word: "The", start: 5, end: 5.2),
                    TranscriptWordTiming(word: "next", start: 5.2, end: 5.4),
                    TranscriptWordTiming(word: "paragraph", start: 5.4, end: 5.8),
                    TranscriptWordTiming(word: "has", start: 5.8, end: 6),
                    TranscriptWordTiming(word: "a", start: 6, end: 6.1),
                    TranscriptWordTiming(word: "comma,", start: 6.1, end: 6.4),
                    TranscriptWordTiming(word: "too.", start: 6.4, end: 6.75)
                ]
            )
        ]

        let timedText = content(
            segments,
            format: .text,
            layout: .compactLines,
            timecodes: .startAndEnd
        )
        precondition(timedText.contains("00:00:01.250 --> 00:00:02.500"))
        precondition(timedText.contains("Hello, \"world\"."))

        let paragraphs = content(
            segments,
            format: .text,
            layout: .paragraphs,
            timecodes: .start
        )
        precondition(paragraphs.contains("00:00:01.250\n"))
        precondition(paragraphs.contains("\n\n"))

        let continuous = content(
            segments,
            format: .markdown,
            layout: .continuousText,
            timecodes: .startAndEnd
        )
        precondition(!continuous.contains("00:00:"))
        precondition(continuous.contains("Hello, \"world\". The next paragraph"))

        let markdown = content(
            segments,
            format: .markdown,
            layout: .compactLines,
            timecodes: .start
        )
        precondition(markdown.contains("**00:00:01.250**"))

        let csv = content(segments, format: .csv)
        precondition(csv.hasPrefix("Start,End,Duration (seconds),Text\n"))
        precondition(csv.contains("\"Hello, \"\"world\"\".\""))

        let json = content(segments, format: .json)
        let jsonObject = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        precondition(jsonObject?["format_version"] as? Int == 1)
        precondition((jsonObject?["segments"] as? [[String: Any]])?.count == 2)

        let srt = content(segments, format: .srt)
        precondition(srt.hasPrefix("1\n00:00:01,250 --> 00:00:02,500"))

        let vtt = content(segments, format: .webVTT)
        precondition(vtt.hasPrefix("WEBVTT\n\n00:00:01.250 --> 00:00:02.500"))

        precondition(TranscriptExportFormat.webVTT.fileExtension == "vtt")
        precondition(TranscriptExportFormat.markdown.fileExtension == "md")
        print("Transcript export smoke test passed.")
    }

    private static func content(
        _ segments: [TranscriptSegment],
        format: TranscriptExportFormat,
        layout: TranscriptExportLayout = .compactLines,
        timecodes: TranscriptExportTimecodeStyle = .start
    ) -> String {
        TranscriptUtilities.content(
            from: segments,
            format: format,
            layout: layout,
            timecodeStyle: timecodes
        )
    }
}
