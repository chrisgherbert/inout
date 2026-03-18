import SwiftUI
import AppKit
import QuartzCore

let transcriptTimeColumnPreferredWidth: CGFloat = 102
let transcriptTimeColumnMinimumWidth: CGFloat = 90
let transcriptTimeColumnMaximumWidth: CGFloat = 120
let transcriptTimeColumnLeadingInset: CGFloat = 0
let transcriptTimeColumnTrailingInset: CGFloat = 10
let transcriptTextColumnLeadingInset: CGFloat = 2
let transcriptTextColumnTrailingInset: CGFloat = 3
let transcriptTextMeasurementPadding: CGFloat = transcriptTextColumnLeadingInset + transcriptTextColumnTrailingInset + 16
let transcriptTableWidthSlack: CGFloat = transcriptTimeColumnTrailingInset + transcriptTextColumnLeadingInset + 14

func normalizedTranscriptSearchText(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
}

func preferredTranscriptTextWidth(
    for rows: [TranscriptDisplayRow],
    fontSize: CGFloat
) -> CGFloat {
    let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize)
    ]

    var widths: [CGFloat] = []
    widths.reserveCapacity(rows.count)
    for row in rows {
        let width = ceil((row.text as NSString).size(withAttributes: baseAttributes).width) + transcriptTextMeasurementPadding
        widths.append(width)
    }

    guard !widths.isEmpty else { return 320 }
    return min(max(320, widths.max() ?? 320), 6_000)
}

func exactTranscriptTableDocumentWidth(
    for rows: [TranscriptDisplayRow],
    fontSize: CGFloat,
    timeColumnWidth: CGFloat = transcriptTimeColumnPreferredWidth
) -> CGFloat {
    timeColumnWidth +
        preferredTranscriptTextWidth(for: rows, fontSize: fontSize) +
        transcriptTableWidthSlack
}

struct TranscriptDisplayRow: Identifiable, Equatable {
    let id: UUID
    let start: Double
    let startLabel: String
    let text: String
    let normalizedText: String
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

final class TranscriptNSScrollView: NSScrollView {
    var onLayoutUpdate: ((TranscriptNSScrollView) -> Void)?
    private var lastReportedContentSize: NSSize = .zero

    override func layout() {
        super.layout()
        let currentSize = contentView.bounds.size
        guard abs(currentSize.width - lastReportedContentSize.width) > 0.5 ||
                abs(currentSize.height - lastReportedContentSize.height) > 0.5 else {
            return
        }
        lastReportedContentSize = currentSize
        onLayoutUpdate?(self)
    }
}

final class TranscriptNSTableRowView: NSTableRowView {
    private let playbackIndicatorLayer = CALayer()
    private let currentMatchOutlineLayer = CAShapeLayer()
    private var hoverTrackingArea: NSTrackingArea?

    var isHovered = false {
        didSet {
            if oldValue != isHovered {
                needsDisplay = true
            }
        }
    }

    var isSearchMatch = false {
        didSet {
            if oldValue != isSearchMatch {
                needsDisplay = true
            }
        }
    }
    var isActivePlaybackRow = false {
        didSet {
            if oldValue != isActivePlaybackRow {
                updatePlaybackIndicator(animated: true)
            }
        }
    }
    var isCurrentSearchResult = false {
        didSet {
            if oldValue != isCurrentSearchResult {
                updateCurrentMatchOutline(animated: true)
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override var isEmphasized: Bool {
        get { false }
        set { }
    }

    override func layout() {
        super.layout()
        updatePlaybackIndicatorFrame()
        updateCurrentMatchOutlineFrame()
        updateHoverStateForCurrentMousePosition()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        updateHoverStateForCurrentMousePosition()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        super.mouseExited(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHoverStateForCurrentMousePosition()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isHovered, !isSelected {
            let hoverRect = bounds.insetBy(dx: 3, dy: 1)
            let hoverPath = NSBezierPath(roundedRect: hoverRect, xRadius: 6, yRadius: 6)
            NSColor.labelColor.withAlphaComponent(0.055).setFill()
            hoverPath.fill()
        }
        guard isSearchMatch, !isSelected else { return }
        let highlightRect = bounds.insetBy(dx: 3, dy: 1)
        let path = NSBezierPath(roundedRect: highlightRect, xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        path.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let selectionRect = bounds.insetBy(dx: 2, dy: 0.5)
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        path.fill()
    }

    private func commonInit() {
        wantsLayer = true
        playbackIndicatorLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        playbackIndicatorLayer.opacity = 0
        playbackIndicatorLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "cornerRadius": NSNull(),
            "backgroundColor": NSNull()
        ]
        layer?.addSublayer(playbackIndicatorLayer)

        currentMatchOutlineLayer.fillColor = NSColor.clear.cgColor
        currentMatchOutlineLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        currentMatchOutlineLayer.lineWidth = 1
        currentMatchOutlineLayer.opacity = 0
        currentMatchOutlineLayer.actions = [
            "path": NSNull(),
            "strokeColor": NSNull(),
            "lineWidth": NSNull()
        ]
        layer?.addSublayer(currentMatchOutlineLayer)
        updatePlaybackIndicatorFrame()
        updateCurrentMatchOutlineFrame()
    }

    func updateHoverStateForCurrentMousePosition() {
        guard let window else {
            if isHovered {
                isHovered = false
            }
            return
        }

        let mouseLocation = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let shouldHover = bounds.contains(mouseLocation)
        if isHovered != shouldHover {
            isHovered = shouldHover
        }
    }

    private func updatePlaybackIndicatorFrame() {
        let barRect = NSRect(x: 3, y: 3, width: 3, height: max(0, bounds.height - 6))
        playbackIndicatorLayer.frame = barRect
        playbackIndicatorLayer.cornerRadius = 1.5
    }

    private func updateCurrentMatchOutlineFrame() {
        let outlineRect = bounds.insetBy(dx: 3, dy: 1)
        currentMatchOutlineLayer.path = CGPath(
            roundedRect: outlineRect,
            cornerWidth: 6,
            cornerHeight: 6,
            transform: nil
        )
    }

    private func updatePlaybackIndicator(animated: Bool) {
        let targetOpacity: Float = isActivePlaybackRow ? 1.0 : 0.0
        updatePlaybackIndicatorFrame()

        if animated {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = playbackIndicatorLayer.presentation()?.opacity ?? playbackIndicatorLayer.opacity
            animation.toValue = targetOpacity
            animation.duration = 0.14
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            playbackIndicatorLayer.add(animation, forKey: "opacity")
        }

        playbackIndicatorLayer.opacity = targetOpacity
    }

    private func updateCurrentMatchOutline(animated: Bool) {
        let targetOpacity: Float = isCurrentSearchResult ? 1.0 : 0.0
        updateCurrentMatchOutlineFrame()

        if animated {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = currentMatchOutlineLayer.presentation()?.opacity ?? currentMatchOutlineLayer.opacity
            animation.toValue = targetOpacity
            animation.duration = 0.14
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            currentMatchOutlineLayer.add(animation, forKey: "opacity")
        }

        currentMatchOutlineLayer.opacity = targetOpacity
    }
}

struct TranscriptTableView: NSViewRepresentable {
    let rows: [TranscriptDisplayRow]
    let rowsVersion: Int
    let fontSize: CGFloat
    var activeRowID: UUID? = nil
    var followsActiveRow = false
    var showsPlaybackIndicator = false
    var searchQuery: String = ""
    var matchingRowIDs: Set<UUID> = []
    var searchVersion: Int = 0
    var currentSearchResultRowID: UUID? = nil
    var requestedSearchRevealRowID: UUID? = nil
    var allowsMultipleSelection = true
    var onUserScrollActivityChanged: ((Bool) -> Void)? = nil
    var onActivateRow: ((TranscriptDisplayRow) -> Void)? = nil
    var onDoubleActivateRow: ((TranscriptDisplayRow) -> Void)? = nil

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [TranscriptDisplayRow] = []
        var rowsVersion: Int = 0
        var fontSize: CGFloat = 14
        var activeRowID: UUID?
        var followsActiveRow = false
        var showsPlaybackIndicator = false
        var searchQuery: String = ""
        var matchingRowIDs: Set<UUID> = []
        var searchVersion: Int = 0
        var currentSearchResultRowID: UUID?
        var requestedSearchRevealRowID: UUID?
        var onActivateRow: ((TranscriptDisplayRow) -> Void)?
        var onDoubleActivateRow: ((TranscriptDisplayRow) -> Void)?
        weak var tableView: TranscriptNSTableView?
        var isApplyingProgrammaticSelection = false
        var lastAppliedActiveRowID: UUID?
        var lastAppliedSearchResultRowID: UUID?
        var lastRequestedSearchRevealRowID: UUID?
        var rowIndexByID: [UUID: Int] = [:]
        var cachedTranscriptTextWidth: CGFloat = 320
        var lastMeasuredRowsVersion: Int = -1
        var lastMeasuredFontSize: CGFloat = -1
        var attributedTextCache: [UUID: NSAttributedString] = [:]
        var lastAttributedCacheRowsVersion: Int = -1
        var lastAttributedCacheSearchVersion: Int = -1
        var lastAttributedCacheFontSize: CGFloat = -1
        var onUserScrollActivityChanged: ((Bool) -> Void)?
        weak var observedScrollView: NSScrollView?
        var boundsDidChangeObserver: NSObjectProtocol?
        var liveScrollStartObserver: NSObjectProtocol?
        var liveScrollEndObserver: NSObjectProtocol?
        var scrollEndWorkItem: DispatchWorkItem?
        var isUserScrolling = false
        var lastObservedClipBounds: NSRect = .zero

        private enum Column {
            static let time = NSUserInterfaceItemIdentifier("transcript_time")
            static let text = NSUserInterfaceItemIdentifier("transcript_text")
        }

        deinit {
            if let boundsDidChangeObserver {
                NotificationCenter.default.removeObserver(boundsDidChangeObserver)
            }
            if let liveScrollStartObserver {
                NotificationCenter.default.removeObserver(liveScrollStartObserver)
            }
            if let liveScrollEndObserver {
                NotificationCenter.default.removeObserver(liveScrollEndObserver)
            }
            scrollEndWorkItem?.cancel()
        }

        func configureScrollObservation(for scrollView: NSScrollView) {
            guard observedScrollView !== scrollView else { return }
            if let boundsDidChangeObserver {
                NotificationCenter.default.removeObserver(boundsDidChangeObserver)
            }
            if let liveScrollStartObserver {
                NotificationCenter.default.removeObserver(liveScrollStartObserver)
            }
            if let liveScrollEndObserver {
                NotificationCenter.default.removeObserver(liveScrollEndObserver)
            }

            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            lastObservedClipBounds = scrollView.contentView.bounds
            boundsDidChangeObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.handleScrollBoundsChange()
            }
            liveScrollStartObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.beginUserScroll()
            }
            liveScrollEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.endUserScroll()
            }
        }

        private func handleScrollBoundsChange() {
            guard let scrollView = observedScrollView else { return }
            let newBounds = scrollView.contentView.bounds
            defer { lastObservedClipBounds = newBounds }

            let originDeltaY = abs(newBounds.origin.y - lastObservedClipBounds.origin.y)
            let originDeltaX = abs(newBounds.origin.x - lastObservedClipBounds.origin.x)
            guard originDeltaY > 0.5 || originDeltaX > 0.5 else { return }
            guard isUserScrolling || isLikelyUserInitiatedScroll else { return }
            beginUserScroll()
            scheduleUserScrollEnd()
        }

        private var isLikelyUserInitiatedScroll: Bool {
            guard let event = NSApp.currentEvent else { return false }
            switch event.type {
            case .scrollWheel, .leftMouseDragged, .otherMouseDragged:
                return true
            default:
                return false
            }
        }

        private func beginUserScroll() {
            scrollEndWorkItem?.cancel()
            if !isUserScrolling {
                isUserScrolling = true
                onUserScrollActivityChanged?(true)
            }
        }

        private func scheduleUserScrollEnd() {
            scrollEndWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.endUserScroll()
            }
            scrollEndWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: workItem)
        }

        private func endUserScroll() {
            scrollEndWorkItem?.cancel()
            scrollEndWorkItem = nil
            guard isUserScrolling else { return }
            isUserScrolling = false
            onUserScrollActivityChanged?(false)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func updateColumnWidths(in scrollView: NSScrollView) {
            guard let tableView else { return }
            guard tableView.tableColumns.count >= 2 else { return }

            scrollView.layoutSubtreeIfNeeded()
            scrollView.contentView.layoutSubtreeIfNeeded()
            tableView.layoutSubtreeIfNeeded()

            let timeColumn = tableView.tableColumns[0]
            let textColumn = tableView.tableColumns[1]

            let visibleDocumentWidth = max(0, scrollView.documentVisibleRect.width)
            let exactDocumentWidth = exactTranscriptTableDocumentWidth(
                for: rows,
                fontSize: fontSize,
                timeColumnWidth: timeColumn.width
            )
            let shouldPreferIntrinsicTextWidth = exactDocumentWidth > (visibleDocumentWidth + 1)

            let availableTextWidth = max(
                0,
                visibleDocumentWidth - timeColumn.width - transcriptTableWidthSlack
            )
            let fillTextWidth = max(280, availableTextWidth)
            let targetWidth = shouldPreferIntrinsicTextWidth
                ? preferredTranscriptTextColumnWidth()
                : fillTextWidth
            if abs(textColumn.width - targetWidth) > 0.5 {
                textColumn.width = targetWidth
            }
            tableView.layoutSubtreeIfNeeded()
            tableView.sizeToFit()
            scrollView.layoutSubtreeIfNeeded()
            scrollView.contentView.layoutSubtreeIfNeeded()

            let actualDocumentWidth = max(
                exactDocumentWidth,
                tableView.tableColumns.reduce(CGFloat(0)) { partial, column in
                    partial + column.width
                }
            )
            let needsHorizontalScrolling = actualDocumentWidth > (visibleDocumentWidth + 1)

            if scrollView.hasHorizontalScroller != needsHorizontalScrolling {
                scrollView.hasHorizontalScroller = needsHorizontalScrolling
                scrollView.tile()
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < rows.count, let tableColumn else { return nil }
            let cellIdentifier = NSUserInterfaceItemIdentifier(tableColumn.identifier.rawValue + "_cell")
            let cell = (tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTableCellView) ?? {
                let cell = NSTableCellView(frame: .zero)
                cell.identifier = cellIdentifier

                let textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byClipping
                textField.maximumNumberOfLines = 1
                cell.addSubview(textField)
                cell.textField = textField

                let leadingInset = tableColumn.identifier == Column.time
                    ? transcriptTimeColumnLeadingInset
                    : transcriptTextColumnLeadingInset
                let trailingInset = tableColumn.identifier == Column.time
                    ? transcriptTimeColumnTrailingInset
                    : transcriptTextColumnTrailingInset

                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leadingInset),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -trailingInset),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
                return cell
            }()

            let item = rows[row]
            if tableColumn.identifier == Column.time {
                cell.textField?.stringValue = item.startLabel
                cell.textField?.textColor = NSColor.secondaryLabelColor
                cell.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: max(11, fontSize - 1), weight: .regular)
                cell.textField?.alignment = .right
            } else {
                cell.textField?.font = NSFont.systemFont(ofSize: fontSize)
                cell.textField?.alignment = .left
                cell.textField?.attributedStringValue = attributedTranscriptText(for: item)
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = TranscriptNSTableRowView()
            if row >= 0, row < rows.count {
                rowView.isSearchMatch = matchingRowIDs.contains(rows[row].id)
                rowView.isActivePlaybackRow = showsPlaybackIndicator && rows[row].id == activeRowID
                rowView.isCurrentSearchResult = rows[row].id == currentSearchResultRowID
                rowView.updateHoverStateForCurrentMousePosition()
            }
            return rowView
        }

        private func preferredTranscriptTextColumnWidth() -> CGFloat {
            if lastMeasuredRowsVersion == rowsVersion,
               abs(lastMeasuredFontSize - fontSize) < 0.001 {
                return cachedTranscriptTextWidth
            }

            let measured = preferredTranscriptTextWidth(for: rows, fontSize: fontSize)
            cachedTranscriptTextWidth = measured
            lastMeasuredRowsVersion = rowsVersion
            lastMeasuredFontSize = fontSize
            return measured
        }

        func refreshVisibleRowStates() {
            guard let tableView else { return }
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.length > 0 else { return }

            let upperBound = min(rows.count, visibleRows.location + visibleRows.length)
            guard visibleRows.location >= 0, visibleRows.location < upperBound else { return }

            for rowIndex in visibleRows.location..<upperBound {
                guard let rowView = tableView.rowView(atRow: rowIndex, makeIfNecessary: false) as? TranscriptNSTableRowView else { continue }
                rowView.isSearchMatch = matchingRowIDs.contains(rows[rowIndex].id)
                rowView.isActivePlaybackRow = showsPlaybackIndicator && rows[rowIndex].id == activeRowID
                rowView.isCurrentSearchResult = rows[rowIndex].id == currentSearchResultRowID
                rowView.updateHoverStateForCurrentMousePosition()
            }
        }

        func refreshVisibleCellContent() {
            guard let tableView else { return }
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.length > 0 else { return }

            let upperBound = min(rows.count, visibleRows.location + visibleRows.length)
            guard visibleRows.location >= 0, visibleRows.location < upperBound else { return }

            for rowIndex in visibleRows.location..<upperBound {
                guard let textCell = tableView.view(atColumn: 1, row: rowIndex, makeIfNecessary: false) as? NSTableCellView else { continue }
                textCell.textField?.attributedStringValue = attributedTranscriptText(for: rows[rowIndex])
            }
        }

        private func attributedTranscriptText(for row: TranscriptDisplayRow) -> NSAttributedString {
            ensureAttributedTextCache()
            if let cached = attributedTextCache[row.id] {
                return cached
            }

            let text = row.text
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: NSColor.labelColor
                ]
            )

            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                let result = NSAttributedString(attributedString: attributed)
                attributedTextCache[row.id] = result
                return result
            }

            let nsText = text as NSString
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.length > 0 {
                let foundRange = nsText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                if foundRange.location == NSNotFound { break }
                attributed.addAttributes([
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.2),
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)
                ], range: foundRange)
                let nextLocation = foundRange.location + foundRange.length
                guard nextLocation < nsText.length else { break }
                searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
            }

            let result = NSAttributedString(attributedString: attributed)
            attributedTextCache[row.id] = result
            return result
        }

        private func ensureAttributedTextCache() {
            guard lastAttributedCacheRowsVersion != rowsVersion ||
                    lastAttributedCacheSearchVersion != searchVersion ||
                    abs(lastAttributedCacheFontSize - fontSize) > 0.001 else {
                return
            }
            attributedTextCache.removeAll(keepingCapacity: true)
            lastAttributedCacheRowsVersion = rowsVersion
            lastAttributedCacheSearchVersion = searchVersion
            lastAttributedCacheFontSize = fontSize
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

        @objc func handleRowAction(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard row >= 0, row < rows.count else { return }
            onActivateRow?(rows[row])
        }

        @objc func handleRowDoubleAction(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard row >= 0, row < rows.count else { return }
            onDoubleActivateRow?(rows[row])
        }

        func applyActiveSelectionIfNeeded(forceScroll: Bool = false) {
            guard let tableView else { return }
            let activeRowChanged = lastAppliedActiveRowID != activeRowID
            let searchRevealChanged = lastRequestedSearchRevealRowID != requestedSearchRevealRowID

            guard activeRowID != nil || currentSearchResultRowID != nil else {
                if showsPlaybackIndicator || !allowsDeselectionWorkaround(tableView.selectedRowIndexes) {
                    return
                }
                isApplyingProgrammaticSelection = true
                tableView.deselectAll(nil)
                isApplyingProgrammaticSelection = false
                lastAppliedActiveRowID = nil
                lastAppliedSearchResultRowID = nil
                lastRequestedSearchRevealRowID = nil
                return
            }

            guard activeRowChanged || searchRevealChanged || forceScroll else {
                lastAppliedSearchResultRowID = currentSearchResultRowID
                return
            }

            if let activeRowID,
               let activeRowIndex = rowIndexByID[activeRowID] {
                if !showsPlaybackIndicator {
                    isApplyingProgrammaticSelection = true
                    tableView.selectRowIndexes(IndexSet(integer: activeRowIndex), byExtendingSelection: false)
                    isApplyingProgrammaticSelection = false
                }
                if followsActiveRow && (activeRowChanged || forceScroll) {
                    revealPlaybackRowIfNeeded(activeRowIndex, in: tableView, forceCentering: forceScroll)
                }
            } else if !showsPlaybackIndicator {
                isApplyingProgrammaticSelection = true
                tableView.deselectAll(nil)
                isApplyingProgrammaticSelection = false
            }

            if let requestedSearchRevealRowID,
               let searchRowIndex = rowIndexByID[requestedSearchRevealRowID],
               (searchRevealChanged || forceScroll),
               !isUserScrolling {
                smoothlyRevealRow(searchRowIndex, in: tableView)
            }
            lastAppliedActiveRowID = activeRowID
            lastAppliedSearchResultRowID = currentSearchResultRowID
            lastRequestedSearchRevealRowID = requestedSearchRevealRowID
        }

        private func revealPlaybackRowIfNeeded(_ rowIndex: Int, in tableView: TranscriptNSTableView, forceCentering: Bool) {
            guard let scrollView = tableView.enclosingScrollView else {
                tableView.scrollRowToVisible(rowIndex)
                return
            }

            let rowRect = tableView.rect(ofRow: rowIndex)
            guard !rowRect.isEmpty else { return }

            let visibleRect = scrollView.documentVisibleRect
            let verticalInset = min(48.0, max(12.0, visibleRect.height * 0.18))
            let relaxedVisibleRect = visibleRect.insetBy(dx: 0, dy: verticalInset)

            if !forceCentering && relaxedVisibleRect.contains(rowRect) {
                return
            }

            smoothlyRevealRow(rowIndex, in: tableView)
        }

        private func allowsDeselectionWorkaround(_ selectedIndexes: IndexSet) -> Bool {
            !selectedIndexes.isEmpty || lastAppliedActiveRowID != nil
        }

        private func smoothlyRevealRow(_ rowIndex: Int, in tableView: TranscriptNSTableView) {
            guard let scrollView = tableView.enclosingScrollView else {
                tableView.scrollRowToVisible(rowIndex)
                return
            }

            let rowRect = tableView.rect(ofRow: rowIndex)
            guard !rowRect.isEmpty else { return }

            let visibleRect = scrollView.documentVisibleRect
            let targetY = max(
                0,
                min(
                    rowRect.midY - (visibleRect.height / 2.0),
                    max(0, tableView.bounds.height - visibleRect.height)
                )
            )

            guard abs(visibleRect.origin.y - targetY) > 1 else { return }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = TranscriptNSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .legacy
        scrollView.borderType = .noBorder
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 2, right: 2)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 2)

        let tableView = TranscriptNSTableView(frame: .zero)
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = showsPlaybackIndicator ? .none : .regular
        tableView.allowsMultipleSelection = allowsMultipleSelection
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
        timeColumn.width = transcriptTimeColumnPreferredWidth
        timeColumn.minWidth = transcriptTimeColumnMinimumWidth
        timeColumn.maxWidth = transcriptTimeColumnMaximumWidth
        timeColumn.resizingMask = .userResizingMask
        tableView.addTableColumn(timeColumn)

        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript_text"))
        textColumn.minWidth = 280
        textColumn.resizingMask = .userResizingMask
        tableView.addTableColumn(textColumn)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing

        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy", action: #selector(Coordinator.copyFromMenu(_:)), keyEquivalent: "")
        copyItem.target = context.coordinator
        menu.addItem(copyItem)
        tableView.menu = menu

        context.coordinator.tableView = tableView
        context.coordinator.rowsVersion = rowsVersion
        context.coordinator.rowIndexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        context.coordinator.activeRowID = activeRowID
        context.coordinator.followsActiveRow = followsActiveRow
        context.coordinator.showsPlaybackIndicator = showsPlaybackIndicator
        context.coordinator.searchQuery = searchQuery
        context.coordinator.matchingRowIDs = matchingRowIDs
        context.coordinator.searchVersion = searchVersion
        context.coordinator.currentSearchResultRowID = currentSearchResultRowID
        context.coordinator.requestedSearchRevealRowID = requestedSearchRevealRowID
        context.coordinator.onUserScrollActivityChanged = onUserScrollActivityChanged
        context.coordinator.onActivateRow = onActivateRow
        context.coordinator.onDoubleActivateRow = onDoubleActivateRow
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.handleRowAction(_:))
        tableView.doubleAction = #selector(Coordinator.handleRowDoubleAction(_:))
        let clipView = NSClipView()
        clipView.drawsBackground = false
        clipView.documentView = tableView
        scrollView.contentView = clipView
        scrollView.onLayoutUpdate = { [weak coordinator = context.coordinator] scrollView in
            coordinator?.updateColumnWidths(in: scrollView)
        }
        context.coordinator.configureScrollObservation(for: scrollView)
        context.coordinator.updateColumnWidths(in: scrollView)

        context.coordinator.applyActiveSelectionIfNeeded(forceScroll: true)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = context.coordinator.tableView else { return }
        let rowsChanged = context.coordinator.rowsVersion != rowsVersion
        let fontChanged = context.coordinator.fontSize != fontSize
        let searchChanged = context.coordinator.searchVersion != searchVersion
        let currentSearchResultChanged = context.coordinator.currentSearchResultRowID != currentSearchResultRowID
        let activeRowChanged = context.coordinator.activeRowID != activeRowID
        let playbackIndicatorChanged = context.coordinator.showsPlaybackIndicator != showsPlaybackIndicator
        let followsActiveRowChanged = context.coordinator.followsActiveRow != followsActiveRow
        let searchRevealChanged = context.coordinator.requestedSearchRevealRowID != requestedSearchRevealRowID
        let selectionModeChanged = tableView.allowsMultipleSelection != allowsMultipleSelection
        let selectionHighlightChanged = tableView.selectionHighlightStyle != (showsPlaybackIndicator ? .none : .regular)
        let shouldReload = rowsChanged || fontChanged
        let hasMeaningfulChanges = shouldReload || searchChanged || currentSearchResultChanged || activeRowChanged || playbackIndicatorChanged || followsActiveRowChanged || searchRevealChanged || selectionModeChanged || selectionHighlightChanged

        if !hasMeaningfulChanges {
            return
        }

        context.coordinator.rows = rows
        if rowsChanged {
            context.coordinator.rowIndexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        }
        context.coordinator.rowsVersion = rowsVersion
        context.coordinator.fontSize = fontSize
        context.coordinator.activeRowID = activeRowID
        context.coordinator.followsActiveRow = followsActiveRow
        context.coordinator.showsPlaybackIndicator = showsPlaybackIndicator
        context.coordinator.searchQuery = searchQuery
        context.coordinator.matchingRowIDs = matchingRowIDs
        context.coordinator.searchVersion = searchVersion
        context.coordinator.currentSearchResultRowID = currentSearchResultRowID
        context.coordinator.requestedSearchRevealRowID = requestedSearchRevealRowID
        context.coordinator.onUserScrollActivityChanged = onUserScrollActivityChanged
        context.coordinator.onActivateRow = onActivateRow
        context.coordinator.onDoubleActivateRow = onDoubleActivateRow
        tableView.allowsMultipleSelection = allowsMultipleSelection
        tableView.selectionHighlightStyle = showsPlaybackIndicator ? .none : .regular
        if shouldReload {
            tableView.reloadData()
            context.coordinator.updateColumnWidths(in: nsView)
        } else {
            if searchChanged {
                context.coordinator.refreshVisibleCellContent()
            }
            if searchChanged || currentSearchResultChanged || activeRowChanged || playbackIndicatorChanged {
                context.coordinator.refreshVisibleRowStates()
            }
        }
        context.coordinator.applyActiveSelectionIfNeeded()
    }
}
