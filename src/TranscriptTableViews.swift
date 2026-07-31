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

struct TranscriptViewOptionsButton: View {
    let mode: TranscriptDisplayMode
    let showsTimecodes: Bool
    let textSize: TranscriptTextSize
    let setMode: (TranscriptDisplayMode) -> Void
    let setShowsTimecodes: (Bool) -> Void
    let setTextSize: (TranscriptTextSize) -> Void
    @State private var showsPopover = false

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            Label("View", systemImage: "textformat")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Transcript View")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Layout")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Layout", selection: Binding(get: { mode }, set: setMode)) {
                        ForEach(TranscriptDisplayMode.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                }

                Divider()

                Toggle(
                    "Show Timecodes",
                    isOn: Binding(get: { showsTimecodes }, set: setShowsTimecodes)
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Text Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Text Size", selection: Binding(get: { textSize }, set: setTextSize)) {
                        ForEach(TranscriptTextSize.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
            }
            .padding(16)
            .frame(width: 250)
        }
        .help("Change transcript layout and appearance")
    }
}

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
    let end: Double
    let startLabel: String
    let text: String
    let normalizedText: String
}

struct TranscriptDisplayRows {
    let rows: [TranscriptDisplayRow]
}

func makeTranscriptDisplayRows(
    from segments: [TranscriptSegment],
    mode: TranscriptDisplayMode = .compact
) -> [TranscriptDisplayRow] {
    makeTranscriptDisplayRowsWithLookup(from: segments, mode: mode).rows
}

func makeTranscriptDisplayRowsWithLookup(
    from segments: [TranscriptSegment],
    mode: TranscriptDisplayMode = .compact
) -> TranscriptDisplayRows {
    var rows: [TranscriptDisplayRow] = []
    rows.reserveCapacity(segments.count)

    for segment in segments {
        let text = normalizedTranscriptDisplayText(segment.text)
        guard !text.isEmpty else { continue }

        if let last = rows.last,
           shouldMergeTranscriptDisplayText(previous: last.text, current: text) {
            let mergedText = mergedTranscriptDisplayText(previous: last.text, current: text)
            rows[rows.count - 1] = TranscriptDisplayRow(
                id: last.id,
                start: last.start,
                end: max(last.end, segment.end),
                startLabel: last.startLabel,
                text: mergedText,
                normalizedText: normalizedTranscriptSearchText(mergedText)
            )
        } else {
            let row = TranscriptDisplayRow(
                id: segment.id,
                start: segment.start,
                end: segment.end,
                startLabel: formatSeconds(segment.start),
                text: text,
                normalizedText: normalizedTranscriptSearchText(text)
            )
            rows.append(row)
        }
    }

    let compactRows = TranscriptDisplayRows(rows: rows)
    guard mode == .paragraphs else { return compactRows }
    return makeParagraphTranscriptDisplayRows(from: segments)
}

private func makeParagraphTranscriptDisplayRows(
    from segments: [TranscriptSegment]
) -> TranscriptDisplayRows {
    var words: [TranscriptTimedWordUnit] = []
    var segmentOrderByID: [UUID: Int] = [:]
    segmentOrderByID.reserveCapacity(segments.count)
    for segment in segments {
        segmentOrderByID[segment.id] = segmentOrderByID.count
        if segment.timedWords.isEmpty {
            let text = normalizedTranscriptDisplayText(segment.text)
            if !text.isEmpty {
                let fallbackWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
                let duration = max(0.05, segment.end - segment.start)
                let wordDuration = duration / Double(max(1, fallbackWords.count))
                words.append(contentsOf: fallbackWords.enumerated().map { index, word in
                    let start = segment.start + (Double(index) * wordDuration)
                    return TranscriptTimedWordUnit(
                        sourceSegmentID: segment.id,
                        text: word,
                        start: start,
                        end: min(segment.end, start + wordDuration)
                    )
                })
            }
        } else {
            words.append(contentsOf: segment.timedWords.map {
                TranscriptTimedWordUnit(
                    sourceSegmentID: segment.id,
                    text: $0.word,
                    start: $0.start,
                    end: $0.end
                )
            })
        }
    }

    let paragraphs = makeOptimizedTranscriptParagraphs(from: words)
    var paragraphRows: [TranscriptDisplayRow] = []
    var usedRowIDs: Set<UUID> = []
    for paragraph in paragraphs {
        let orderedSegmentIDs = paragraph.sourceSegmentIDs.sorted {
            (segmentOrderByID[$0] ?? .max) < (segmentOrderByID[$1] ?? .max)
        }
        guard let firstSegmentID = orderedSegmentIDs.first else { continue }
        let rowID = usedRowIDs.insert(firstSegmentID).inserted ? firstSegmentID : UUID()
        let text = normalizedTranscriptDisplayText(paragraph.text)
        paragraphRows.append(
            TranscriptDisplayRow(
                id: rowID,
                start: paragraph.start,
                end: paragraph.end,
                startLabel: formatSeconds(paragraph.start),
                text: text,
                normalizedText: normalizedTranscriptSearchText(text)
            )
        )
    }
    return TranscriptDisplayRows(rows: paragraphRows)
}

func activeTranscriptDisplayRowID(
    at time: Double,
    in rows: [TranscriptDisplayRow]
) -> UUID? {
    guard !rows.isEmpty else { return nil }
    let trailingGrace: Double = 0.55
    let leadingGrace: Double = 0.12
    var low = 0
    var high = rows.count - 1

    while low <= high {
        let mid = (low + high) / 2
        let row = rows[mid]
        if time < row.start {
            high = mid - 1
        } else if time >= row.end {
            low = mid + 1
        } else {
            return row.id
        }
    }

    if high >= 0, high < rows.count {
        let previous = rows[high]
        if time >= previous.start, time <= previous.end + trailingGrace {
            return previous.id
        }
    }
    if low >= 0, low < rows.count {
        let upcoming = rows[low]
        if time < upcoming.start, upcoming.start - time <= leadingGrace {
            return upcoming.id
        }
    }
    return nil
}

private func normalizedTranscriptDisplayText(_ text: String) -> String {
    var result = text.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: #"\s+([,.;:!?])"#,
        with: "$1",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: #"([^0-9]),(?=[0-9])"#,
        with: "$1, ",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: #"([a-z])([0-9])"#,
        with: "$1 $2",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: #"([0-9])([A-Z][a-z])"#,
        with: "$1 $2",
        options: .regularExpression
    )
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func shouldMergeTranscriptDisplayText(previous: String, current: String) -> Bool {
    let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !previous.isEmpty, let first = current.first else { return false }

    if transcriptLeadingPunctuation.contains(first) {
        if ",;:".contains(first),
           let previousLast = previous.last,
           ".!?".contains(previousLast) {
            return false
        }
        return true
    }

    guard let previousLast = previous.last,
          previousLast.isLetter || previousLast.isNumber,
          first.isLowercase else {
        return false
    }

    let firstPiece = current.split(separator: " ", maxSplits: 1).first.map(String.init) ?? current
    return firstPiece.count <= 4 && firstPiece.contains(where: { transcriptTrailingPunctuation.contains($0) })
}

private func mergedTranscriptDisplayText(previous: String, current: String) -> String {
    let previous = previous.trimmingCharacters(in: .whitespacesAndNewlines)
    var current = current.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !previous.isEmpty else { return current }
    guard let first = current.first else { return previous }

    if transcriptLeadingPunctuation.contains(first) {
        if first == ",",
           let previousLast = previous.last,
           !previousLast.isNumber,
           current.dropFirst().first?.isNumber == true {
            current.removeFirst()
            current = current.trimmingCharacters(in: .whitespacesAndNewlines)
            return current.isEmpty ? previous : previous + ", " + current
        }
        if let previousLast = previous.last,
           previousLast == first || (".!?".contains(previousLast) && ".!?".contains(first)) {
            current.removeFirst()
            current = current.trimmingCharacters(in: .whitespacesAndNewlines)
            return current.isEmpty ? previous : previous + " " + current
        }
        return previous + current
    }

    let firstPiece = current.split(separator: " ", maxSplits: 1).first.map(String.init) ?? current
    if firstPiece.count <= 4,
       firstPiece.contains(where: { transcriptTrailingPunctuation.contains($0) }) {
        return previous + current
    }

    return previous + " " + current
}

private let transcriptLeadingPunctuation = Set(".,;:!?)]}%")
private let transcriptTrailingPunctuation = Set(".,;:!?")

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
        PlayheadDiagnostics.shared.noteTranscriptRowLayout()
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

private final class TranscriptNSTableCellView: NSTableCellView {
    private var centerYConstraint: NSLayoutConstraint?
    private var topConstraint: NSLayoutConstraint?
    private var bottomConstraint: NSLayoutConstraint?

    func installTextField(
        _ textField: NSTextField,
        leadingInset: CGFloat,
        trailingInset: CGFloat
    ) {
        addSubview(textField)
        self.textField = textField

        let centerYConstraint = textField.centerYAnchor.constraint(equalTo: centerYAnchor)
        let topConstraint = textField.topAnchor.constraint(equalTo: topAnchor, constant: 6)
        let bottomConstraint = textField.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
            centerYConstraint
        ])
        self.centerYConstraint = centerYConstraint
        self.topConstraint = topConstraint
        self.bottomConstraint = bottomConstraint
    }

    func configure(for mode: TranscriptDisplayMode, wrapsText: Bool) {
        guard let textField else { return }
        let usesParagraphs = mode == .paragraphs
        let shouldWrap = usesParagraphs && wrapsText
        centerYConstraint?.isActive = !usesParagraphs
        topConstraint?.isActive = usesParagraphs
        bottomConstraint?.isActive = usesParagraphs
        textField.lineBreakMode = shouldWrap ? .byWordWrapping : .byClipping
        textField.maximumNumberOfLines = shouldWrap ? 0 : 1
        textField.setContentCompressionResistancePriority(
            shouldWrap ? .defaultLow : .defaultHigh,
            for: .horizontal
        )
        textField.cell?.wraps = shouldWrap
        textField.cell?.isScrollable = !shouldWrap
        textField.cell?.usesSingleLineMode = !shouldWrap
        textField.cell?.truncatesLastVisibleLine = false
    }
}

struct TranscriptTableView: NSViewRepresentable {
    let rows: [TranscriptDisplayRow]
    let rowsVersion: Int
    let fontSize: CGFloat
    var displayMode: TranscriptDisplayMode = .compact
    var showsTimecodes = true
    var playbackPresentation: ClipTranscriptPlaybackPresentation? = nil
    var activeRowID: UUID? = nil
    var allowsPlaybackRow = true
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
        var displayMode: TranscriptDisplayMode = .compact
        var showsTimecodes = true
        var activeRowID: UUID?
        var allowsPlaybackRow = true
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
        var segmentRowHeightCache: [UUID: CGFloat] = [:]
        var segmentRowHeightWidth: CGFloat = -1
        var segmentHeightRefreshWorkItem: DispatchWorkItem?

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
            segmentHeightRefreshWorkItem?.cancel()
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

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard displayMode == .paragraphs, row >= 0, row < rows.count else { return 24 }
            let textWidth = max(
                80,
                (tableView.tableColumns.dropFirst().first?.width ?? 280) -
                    transcriptTextColumnLeadingInset -
                    transcriptTextColumnTrailingInset
            )
            if abs(segmentRowHeightWidth - textWidth) > 0.5 {
                segmentRowHeightCache.removeAll(keepingCapacity: true)
                segmentRowHeightWidth = textWidth
            }
            let item = rows[row]
            if let cached = segmentRowHeightCache[item.id] {
                return cached
            }

            let height = transcriptSegmentRowHeight(
                text: item.text,
                textWidth: textWidth,
                fontSize: fontSize
            )
            segmentRowHeightCache[item.id] = height
            return height
        }

        func invalidateSegmentRowHeights() {
            segmentRowHeightCache.removeAll(keepingCapacity: true)
            segmentRowHeightWidth = -1
        }

        private func scheduleSegmentRowHeightRefresh() {
            segmentHeightRefreshWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let tableView = self.tableView, !self.rows.isEmpty else { return }
                tableView.noteHeightOfRows(
                    withIndexesChanged: IndexSet(integersIn: 0..<self.rows.count)
                )
            }
            segmentHeightRefreshWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        }

        func updateColumnWidths(in scrollView: NSScrollView) {
            guard let tableView else { return }
            guard tableView.tableColumns.count >= 2 else { return }

            scrollView.layoutSubtreeIfNeeded()
            scrollView.contentView.layoutSubtreeIfNeeded()
            tableView.layoutSubtreeIfNeeded()

            let timeColumn = tableView.tableColumns[0]
            let textColumn = tableView.tableColumns[1]
            timeColumn.isHidden = !showsTimecodes
            let visibleTimeColumnWidth = showsTimecodes ? timeColumn.width : 0

            let visibleDocumentWidth = max(0, scrollView.documentVisibleRect.width)
            if displayMode == .paragraphs {
                let targetWidth = max(
                    280,
                    visibleDocumentWidth - visibleTimeColumnWidth - transcriptTableWidthSlack
                )
                let widthChanged = abs(textColumn.width - targetWidth) > 0.5
                if widthChanged {
                    textColumn.width = targetWidth
                    invalidateSegmentRowHeights()
                    scheduleSegmentRowHeightRefresh()
                }
                if scrollView.hasHorizontalScroller {
                    scrollView.hasHorizontalScroller = false
                    scrollView.tile()
                }
                return
            }

            segmentHeightRefreshWorkItem?.cancel()
            segmentHeightRefreshWorkItem = nil
            let exactDocumentWidth = visibleTimeColumnWidth +
                preferredTranscriptTextColumnWidth() +
                transcriptTableWidthSlack
            let shouldPreferIntrinsicTextWidth = exactDocumentWidth > (visibleDocumentWidth + 1)

            let availableTextWidth = max(
                0,
                visibleDocumentWidth - visibleTimeColumnWidth - transcriptTableWidthSlack
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
            let cell = (tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? TranscriptNSTableCellView) ?? {
                PlayheadDiagnostics.shared.noteTranscriptCellCreated()
                let cell = TranscriptNSTableCellView(frame: .zero)
                cell.identifier = cellIdentifier

                let textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false

                let leadingInset = tableColumn.identifier == Column.time
                    ? transcriptTimeColumnLeadingInset
                    : transcriptTextColumnLeadingInset
                let trailingInset = tableColumn.identifier == Column.time
                    ? transcriptTimeColumnTrailingInset
                    : transcriptTextColumnTrailingInset

                cell.installTextField(
                    textField,
                    leadingInset: leadingInset,
                    trailingInset: trailingInset
                )
                return cell
            }()

            let item = rows[row]
            cell.configure(
                for: displayMode,
                wrapsText: tableColumn.identifier == Column.text
            )
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
            PlayheadDiagnostics.shared.noteTranscriptRowViewCreated()
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
                refreshRowState(at: rowIndex, in: tableView)
            }
        }

        func refreshRowStates(forRowIDs rowIDs: [UUID?]) {
            guard let tableView else { return }
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.length > 0 else { return }

            let visibleRange = visibleRows.location..<(visibleRows.location + visibleRows.length)
            let uniqueRowIndexes: Set<Int> = Set(
                rowIDs.compactMap { rowID in
                    guard let rowID, let rowIndex = rowIndexByID[rowID], visibleRange.contains(rowIndex) else {
                        return nil
                    }
                    return rowIndex
                }
            )

            for rowIndex in uniqueRowIndexes {
                refreshRowState(at: rowIndex, in: tableView)
            }
        }

        func applyPlaybackActiveRowID(_ proposedRowID: UUID?) {
            let diagnosticsStart = CACurrentMediaTime()
            let resolvedRowID = allowsPlaybackRow ? proposedRowID : nil
            guard activeRowID != resolvedRowID else { return }

            let previousRowID = activeRowID
            activeRowID = resolvedRowID
            refreshRowStates(forRowIDs: [previousRowID, resolvedRowID])
            applyActiveSelectionIfNeeded()
            MainActor.assumeIsolated {
                PlayheadDiagnostics.shared.noteTranscriptTableUpdate(
                    duration: CACurrentMediaTime() - diagnosticsStart
                )
            }
        }

        private func refreshRowState(at rowIndex: Int, in tableView: TranscriptNSTableView) {
            guard rowIndex >= 0, rowIndex < rows.count,
                  let rowView = tableView.rowView(atRow: rowIndex, makeIfNecessary: false) as? TranscriptNSTableRowView else {
                return
            }

            rowView.isSearchMatch = matchingRowIDs.contains(rows[rowIndex].id)
            rowView.isActivePlaybackRow = showsPlaybackIndicator && rows[rowIndex].id == activeRowID
            rowView.isCurrentSearchResult = rows[rowIndex].id == currentSearchResultRowID
            rowView.updateHoverStateForCurrentMousePosition()
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

        private func copyRows(at indexes: IndexSet) {
            guard !indexes.isEmpty else { return }

            let lines = indexes.compactMap { index -> String? in
                guard index >= 0, index < rows.count else { return nil }
                let row = rows[index]
                return showsTimecodes ? "\(row.startLabel)  \(row.text)" : row.text
            }
            let payload = lines.joined(separator: "\n")
            guard !payload.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payload, forType: .string)
        }

        func copySelection() {
            guard let tableView else { return }
            copyRows(at: tableView.selectedRowIndexes)
        }

        @objc func copyFromMenu(_ sender: Any?) {
            guard let tableView else { return }
            let clickedRow = tableView.clickedRow
            guard clickedRow >= 0, clickedRow < rows.count else { return }
            copyRows(at: IndexSet(integer: clickedRow))
        }

        @objc func handleRowAction(_ sender: Any?) {
            guard let tableView else { return }
            guard !currentEventUsesSelectionModifier else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard row >= 0, row < rows.count else { return }
            onActivateRow?(rows[row])
        }

        @objc func handleRowDoubleAction(_ sender: Any?) {
            guard let tableView else { return }
            guard !currentEventUsesSelectionModifier else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard row >= 0, row < rows.count else { return }
            onDoubleActivateRow?(rows[row])
        }

        private var currentEventUsesSelectionModifier: Bool {
            guard let event = NSApp.currentEvent else { return false }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return modifiers.contains(.command) || modifiers.contains(.shift)
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
            let verticalInset = min(64.0, max(18.0, visibleRect.height * 0.22))
            let deadZoneRect = visibleRect.insetBy(dx: 0, dy: verticalInset)

            let targetY: CGFloat
            if forceCentering {
                targetY = rowRect.midY - (visibleRect.height / 2.0)
            } else if rowRect.maxY > deadZoneRect.maxY {
                targetY = rowRect.midY - (visibleRect.height * 0.72)
            } else if rowRect.minY < deadZoneRect.minY {
                targetY = rowRect.midY - (visibleRect.height * 0.28)
            } else {
                return
            }
            let clampedTargetY = max(
                0,
                min(targetY, max(0, tableView.bounds.height - visibleRect.height))
            )

            let clipView = scrollView.contentView
            if abs(clipView.bounds.origin.y - clampedTargetY) > 1 {
                let followStart = CACurrentMediaTime()
                clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: clampedTargetY))
                scrollView.reflectScrolledClipView(clipView)
                MainActor.assumeIsolated {
                    PlayheadDiagnostics.shared.noteTranscriptFollow(
                        duration: CACurrentMediaTime() - followStart
                    )
                }
            }
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
        tableView.selectionHighlightStyle = showsPlaybackIndicator && !allowsMultipleSelection ? .none : .regular
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
        context.coordinator.rows = rows
        context.coordinator.rowsVersion = rowsVersion
        context.coordinator.fontSize = fontSize
        context.coordinator.displayMode = displayMode
        context.coordinator.showsTimecodes = showsTimecodes
        context.coordinator.rowIndexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        context.coordinator.allowsPlaybackRow = allowsPlaybackRow
        context.coordinator.activeRowID = allowsPlaybackRow
            ? (playbackPresentation?.activeRowID ?? activeRowID)
            : nil
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
        tableView.reloadData()
        context.coordinator.configureScrollObservation(for: scrollView)
        context.coordinator.updateColumnWidths(in: scrollView)
        playbackPresentation?.activeRowDidChange = { [weak coordinator = context.coordinator] rowID in
            coordinator?.applyPlaybackActiveRowID(rowID)
        }

        context.coordinator.applyActiveSelectionIfNeeded(forceScroll: true)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = context.coordinator.tableView else { return }
        let diagnosticsStart = CACurrentMediaTime()
        let previousActiveRowID = context.coordinator.activeRowID
        let resolvedActiveRowID = allowsPlaybackRow
            ? (playbackPresentation?.activeRowID ?? activeRowID)
            : nil
        let previousCurrentSearchResultRowID = context.coordinator.currentSearchResultRowID
        let rowsChanged = context.coordinator.rowsVersion != rowsVersion
        let fontChanged = context.coordinator.fontSize != fontSize
        let displayModeChanged = context.coordinator.displayMode != displayMode
        let timecodeVisibilityChanged = context.coordinator.showsTimecodes != showsTimecodes
        let searchChanged = context.coordinator.searchVersion != searchVersion
        let currentSearchResultChanged = context.coordinator.currentSearchResultRowID != currentSearchResultRowID
        let activeRowChanged = context.coordinator.activeRowID != resolvedActiveRowID
        let playbackIndicatorChanged = context.coordinator.showsPlaybackIndicator != showsPlaybackIndicator
        let followsActiveRowChanged = context.coordinator.followsActiveRow != followsActiveRow
        let searchRevealChanged = context.coordinator.requestedSearchRevealRowID != requestedSearchRevealRowID
        let selectionModeChanged = tableView.allowsMultipleSelection != allowsMultipleSelection
        let desiredSelectionHighlightStyle: NSTableView.SelectionHighlightStyle =
            showsPlaybackIndicator && !allowsMultipleSelection ? .none : .regular
        let selectionHighlightChanged = tableView.selectionHighlightStyle != desiredSelectionHighlightStyle
        let shouldReload = rowsChanged || fontChanged || displayModeChanged || timecodeVisibilityChanged
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
        context.coordinator.displayMode = displayMode
        context.coordinator.showsTimecodes = showsTimecodes
        context.coordinator.allowsPlaybackRow = allowsPlaybackRow
        context.coordinator.activeRowID = resolvedActiveRowID
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
        tableView.selectionHighlightStyle = desiredSelectionHighlightStyle
        if shouldReload {
            PlayheadDiagnostics.shared.noteModelWrite("transcript_table_reload")
            if rowsChanged || fontChanged || displayModeChanged {
                context.coordinator.invalidateSegmentRowHeights()
            }
            tableView.reloadData()
            context.coordinator.updateColumnWidths(in: nsView)
        } else {
            if searchChanged {
                context.coordinator.refreshVisibleCellContent()
            }
            if searchChanged || playbackIndicatorChanged {
                context.coordinator.refreshVisibleRowStates()
            } else if currentSearchResultChanged || activeRowChanged {
                context.coordinator.refreshRowStates(
                    forRowIDs: [
                        previousActiveRowID,
                        resolvedActiveRowID,
                        previousCurrentSearchResultRowID,
                        currentSearchResultRowID
                    ]
                )
            }
        }
        context.coordinator.applyActiveSelectionIfNeeded()
        PlayheadDiagnostics.shared.noteTranscriptTableUpdate(
            duration: CACurrentMediaTime() - diagnosticsStart
        )
    }
}
