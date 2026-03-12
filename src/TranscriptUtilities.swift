import AppKit
import Foundation
import UniformTypeIdentifiers

enum TranscriptUtilities {
    static func plainText(from segments: [TranscriptSegment]) -> String {
        segments
            .map(\.formatted)
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

    static func makeExportPanel(defaultName: String) -> (panel: NSSavePanel, formatPopup: NSPopUpButton) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "srt") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        panel.message = "Export transcript as TXT or SRT"
        panel.prompt = "Export"

        let formatLabel = NSTextField(labelWithString: "Format:")
        formatLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.addItems(withTitles: ["Plain Text (.txt)", "SubRip (.srt)"])
        formatPopup.selectItem(at: 0)
        formatPopup.controlSize = .small
        formatPopup.frame.size.width = 150

        let rowStack = NSStackView(views: [formatLabel, formatPopup])
        rowStack.orientation = .horizontal
        rowStack.alignment = .firstBaseline
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let accessoryContainer = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 30))
        accessoryContainer.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: accessoryContainer.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(lessThanOrEqualTo: accessoryContainer.trailingAnchor, constant: -8),
            rowStack.centerYAnchor.constraint(equalTo: accessoryContainer.centerYAnchor)
        ])
        panel.accessoryView = accessoryContainer
        return (panel, formatPopup)
    }
}
