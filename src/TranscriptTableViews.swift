import SwiftUI
import AppKit

struct TranscriptDisplayRow: Identifiable, Equatable {
    let id: UUID
    let start: Double
    let startLabel: String
    let text: String
}

final class TranscriptNSTableView: NSTableView {
    var copySelectionHandler: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copySelectionHandler?()
            return
        }
        super.keyDown(with: event)
    }
}

struct TranscriptTableView: NSViewRepresentable {
    let rows: [TranscriptDisplayRow]
    let fontSize: CGFloat

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [TranscriptDisplayRow] = []
        var fontSize: CGFloat = 14
        weak var tableView: TranscriptNSTableView?

        private enum Column {
            static let time = NSUserInterfaceItemIdentifier("transcript_time")
            static let text = NSUserInterfaceItemIdentifier("transcript_text")
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < rows.count, let tableColumn else { return nil }
            let cellIdentifier = NSUserInterfaceItemIdentifier(tableColumn.identifier.rawValue + "_cell")
            let cell = (tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTableCellView) ?? {
                let cell = NSTableCellView(frame: .zero)
                cell.identifier = cellIdentifier

                let textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingTail
                textField.maximumNumberOfLines = 1
                cell.addSubview(textField)
                cell.textField = textField

                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
                return cell
            }()

            let item = rows[row]
            if tableColumn.identifier == Column.time {
                cell.textField?.stringValue = item.startLabel
                cell.textField?.textColor = NSColor.secondaryLabelColor
                cell.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: max(11, fontSize - 1), weight: .regular)
                cell.textField?.alignment = .left
            } else {
                cell.textField?.stringValue = item.text
                cell.textField?.textColor = NSColor.labelColor
                cell.textField?.font = NSFont.systemFont(ofSize: fontSize)
                cell.textField?.alignment = .left
            }
            return cell
        }

        func copySelection() {
            guard let tableView else { return }
            let selected = tableView.selectedRowIndexes
            guard !selected.isEmpty else { return }

            let lines = selected.compactMap { index -> String? in
                guard index >= 0, index < rows.count else { return nil }
                let row = rows[index]
                return "\(row.startLabel)  \(row.text)"
            }
            let payload = lines.joined(separator: "\n")
            guard !payload.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payload, forType: .string)
        }

        @objc func copyFromMenu(_ sender: Any?) {
            copySelection()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let tableView = TranscriptNSTableView(frame: .zero)
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.focusRingType = .none
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.copySelectionHandler = { [weak coordinator = context.coordinator] in
            coordinator?.copySelection()
        }

        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript_time"))
        timeColumn.width = 122
        timeColumn.minWidth = 104
        timeColumn.maxWidth = 150
        timeColumn.resizingMask = .userResizingMask
        tableView.addTableColumn(timeColumn)

        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript_text"))
        textColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(textColumn)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy", action: #selector(Coordinator.copyFromMenu(_:)), keyEquivalent: "")
        copyItem.target = context.coordinator
        menu.addItem(copyItem)
        tableView.menu = menu

        context.coordinator.tableView = tableView
        let clipView = NSClipView()
        clipView.drawsBackground = false
        clipView.documentView = tableView
        scrollView.contentView = clipView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = context.coordinator.tableView else { return }
        context.coordinator.rows = rows
        context.coordinator.fontSize = fontSize
        tableView.reloadData()
    }
}
