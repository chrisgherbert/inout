import AppKit
import SwiftUI
import InOutCore

// Exercise the real sidebar, including its row cache and native table. The parent
// deliberately retains the same view inputs, as the player stage's EquatableView can.
@MainActor
private struct RetainedTranscriptStage: View, Equatable {
    let workspace: WorkspaceViewModel
    let source: SourcePresentationModel
    let playback: ClipTranscriptPlaybackPresentation
    let mode: TranscriptDisplayMode

    static func == (lhs: Self, rhs: Self) -> Bool { true }

    var body: some View {
        ClipTranscriptSidebarView(
            workspace: workspace,
            timecodeDisplayStyle: TimecodeDisplayStyle.precise.format,
            timecodeFrameRate: 30,
            timecodeMediaDuration: 100,
            playbackPresentation: playback,
            sourcePresentation: source,
            canGenerateTranscript: true,
            hasAudioTrack: true,
            isPlaying: false,
            isScrubbing: false,
            isOptionKeyPressed: false,
            reduceTransparency: true,
            focusSearchFieldToken: 0,
            transcriptExportFormat: .text,
            transcriptExportLayout: .compactLines,
            transcriptExportTimecodeStyle: .start,
            transcriptDisplayMode: mode,
            transcriptShowsTimecodes: true,
            transcriptTextSize: .medium,
            smartMarkerTabs: [],
            activeSmartMarkerTabID: nil,
            showsSmartMarkerSuggestions: false,
            smartMarkerRevision: 0,
            generateTranscript: {},
            setTranscriptExportFormat: { _ in }, setTranscriptExportLayout: { _ in },
            setTranscriptExportTimecodeStyle: { _ in }, setTranscriptDisplayMode: { _ in },
            setTranscriptShowsTimecodes: { _ in }, setTranscriptTextSize: { _ in },
            exportTranscript: { _, _ in }, seekToTranscriptTime: { _ in },
            playTranscriptFromTime: { _ in }, setShowsSmartMarkerSuggestions: { _ in },
            selectSmartMarkerTab: { _ in }, closeSmartMarkerTab: { _ in },
            startNewSmartMarkerAnalysis: {}, highlightSmartMarker: { _ in },
            playSmartMarker: { _ in }, deleteSmartMarkerSuggestion: { _ in },
            setSmartMarkerScrollPosition: { _, _ in }, selectSmartMarkerResultVersion: { _, _ in },
            cancelSmartMarkerAnalysis: { _ in }, refineSmartMarkerAnalysis: { _, _ in },
            undoSmartMarkerRefinement: { _ in }, onCloseTranscript: {}
        ).equatable()
    }
}

@main
private struct TranscriptSidebarSmoke {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        if CommandLine.arguments.contains("--preview") {
            showPreview()
            return
        }
        NSApp.setActivationPolicy(.prohibited)
        for mode in TranscriptDisplayMode.allCases {
            try verify(mode)
        }
        verifyCompactSearchField()
        verifyCompactAppliedHeader()
        try verifyAcceptAllAndUndo()
        print("Transcript sidebar smoke passed (source → retained stage → sidebar → native cells; apply, restore, repeated correction, clear).")
    }

    @MainActor
    private static func showPreview() {
        NSApp.setActivationPolicy(.regular)
        let model = WorkspaceViewModel()
        let text = "There are constant shots at Cash Patel and then Bill Crystal joins the conversation."
        let tokens = text.split(separator: " ").map(String.init)
        let source = [TranscriptSegment(start: 10, end: 24, text: text,
            timedWords: tokens.enumerated().map { TranscriptWordTiming(word: $0.element, start: 10 + Double($0.offset), end: 11 + Double($0.offset)) })]
        model.transcriptSegments = source
        model.transcriptStatusText = "Loaded preview transcript."
        let playback = ClipTranscriptPlaybackPresentation()
        playback.configure(displayRows: makeTranscriptDisplayRows(from: source))
        model.transcriptCleanup.start(source: source, sourceID: model.sourceSessionID) { callbacks in
            await callbacks.progress(0, tokens.count)
            return [TranscriptCleanupEdit(startWord: 5, endWord: 5, original: "Cash", replacement: "Kash"),
                    TranscriptCleanupEdit(startWord: 10, endWord: 10, original: "Crystal", replacement: "Kristol")]
        }
        let view = VStack(spacing: 0) {
            RetainedTranscriptStage(workspace: model, source: model.sourcePresentation, playback: playback, mode: .compact)
                .padding(12)
            TranscriptCleanupFooterRow(session: model.transcriptCleanup,
                review: { model.reviewTranscriptCleanup() },
                applyAll: { try? model.applyTranscriptCleanup(acceptAll: true) },
                retry: {}, undo: { try? model.undoTranscriptCleanup() })
                .padding(12)
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1050, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Transcript Cleanup UI Preview"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.run()
    }

    @MainActor
    private static func verifyCompactSearchField() {
        let field = TranscriptSidebarSearchField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.stringValue = "ludi"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = field
        defer { window.close() }
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 22)
        field.configureMatches(displayText: nil, hasMatches: false)
        field.layoutSubtreeIfNeeded()
        let cell = field.cell as! NSSearchFieldCell
        let plainRect = cell.searchTextRect(forBounds: field.bounds)
        let clearRect = cell.cancelButtonRect(forBounds: field.bounds)
        field.configureMatches(displayText: "2 of 2", hasMatches: true)
        field.layoutSubtreeIfNeeded()
        let withMatches = cell.searchTextRect(forBounds: field.bounds)
        precondition(withMatches.width < plainRect.width - 40, "Match controls overlap the search query")
        precondition(cell.cancelButtonRect(forBounds: field.bounds) == clearRect, "Match controls moved the native clear button")
        let accessibleNavigation = (field.accessibilityChildren() ?? []).compactMap { $0 as? NSButton }
        precondition(accessibleNavigation.contains { $0.accessibilityLabel() == "Next match" },
                     "Integrated navigation is missing from accessibility")
        precondition(field.isEditable && field.isSelectable, "Native search text is not editable")
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() else { preconditionFailure("Search did not start editing") }
        do {
            editor.selectedRange = NSRange(location: 2, length: 0)
            field.configureMatches(displayText: "123 of 456", hasMatches: true)
            field.layoutSubtreeIfNeeded()
            precondition(editor.string == "ludi" && editor.selectedRange == NSRange(location: 2, length: 0),
                         "Updating match navigation changed the query or caret")
        }
        field.configureMatches(displayText: nil, hasMatches: false)
        field.layoutSubtreeIfNeeded()
        precondition(cell.searchTextRect(forBounds: field.bounds).width == plainRect.width,
                     "Clearing search did not return accessory space to the query")
    }

    @MainActor
    private static func verifyCompactAppliedHeader() {
        let model = WorkspaceViewModel()
        let source = [TranscriptSegment(start: 0, end: 1, text: "A transcript passage.",
            timedWords: [TranscriptWordTiming(word: "A transcript passage.", start: 0, end: 1)])]
        model.transcriptSegments = source
        model.transcriptCleanup.didApply(count: 67, before: source, after: source, sourceID: model.sourceSessionID)
        let playback = ClipTranscriptPlaybackPresentation()
        playback.configure(displayRows: makeTranscriptDisplayRows(from: source))
        let host = NSHostingView(rootView: RetainedTranscriptStage(workspace: model, source: model.sourcePresentation,
                                                                 playback: playback, mode: .compact))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 500)
        defer { window.close() }
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable($0) }.first
        }
        let deadline = Date().addingTimeInterval(3)
        while findTable(host) == nil && Date() < deadline {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        host.layoutSubtreeIfNeeded()
        guard let scroll = findTable(host)?.enclosingScrollView else {
            preconditionFailure("Compact header fixture did not display its transcript")
        }
        func findSearchFields(_ view: NSView) -> [TranscriptSidebarSearchField] {
            if let field = view as? TranscriptSidebarSearchField { return [field] }
            return view.subviews.flatMap { findSearchFields($0) }
        }
        func checkTopInset(maximum: CGFloat) {
            let frame = scroll.convert(scroll.bounds, to: host)
            let topInset = host.isFlipped ? frame.minY - host.bounds.minY : host.bounds.maxY - frame.maxY
            precondition(topInset < maximum, "Toolbar consumes too many rows: \(topInset)px")
        }
        checkTopInset(maximum: 90)
        let fields = findSearchFields(host)
        precondition(fields.count == 1, "Toolbar duplicated the search field")
        let searchField = fields[0]
        searchField.stringValue = "passage"
        searchField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        window.makeFirstResponder(searchField)
        let editor = searchField.currentEditor()
        editor?.selectedRange = NSRange(location: 3, length: 0)
        window.setContentSize(NSSize(width: 380, height: 500))
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 500)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        checkTopInset(maximum: 120)
        precondition(findSearchFields(host).count == 1 && findSearchFields(host)[0] === searchField,
                     "Wrapping toolbar recreated the active search field")
        precondition(searchField.stringValue == "passage", "Wrapping toolbar lost the search query")
        if let editor {
            precondition(searchField.currentEditor() === editor && editor.selectedRange == NSRange(location: 3, length: 0),
                         "Wrapping toolbar moved the search caret")
        }
    }

    @MainActor
    private static func verifyAcceptAllAndUndo() throws {
        let model = WorkspaceViewModel()
        let source = [TranscriptSegment(start: 1, end: 3, text: "Cash Patel", timedWords: [
            TranscriptWordTiming(word: "Cash", start: 1, end: 2),
            TranscriptWordTiming(word: "Patel", start: 2, end: 3)
        ])]
        model.transcriptSegments = source
        let session = model.transcriptCleanup
        model.runTranscriptCleanup { _ in
            [TranscriptCleanupEdit(startWord: 0, endWord: 0, original: "Cash", replacement: "Kash")]
        }
        let deadline = Date().addingTimeInterval(3)
        while session.phase == .running && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(session.phase == .ready)
        session.selected = []
        model.reviewTranscriptCleanup()
        precondition(session.isReviewing && model.selectedTool == .clip)
        try model.applyTranscriptCleanup(acceptAll: true)
        precondition(model.transcriptSegments[0].text == "Kash Patel", "Accept All depended on review selection")
        precondition(session.phase == .applied && session.appliedCount == 1 && !session.isReviewing)
        precondition(TranscriptCleanup.matches(model.transcriptSegments, session.snapshot))
        try model.undoTranscriptCleanup()
        precondition(TranscriptCleanup.matches(source, model.transcriptSegments), "Undo changed timing or text")
        precondition(session.phase == .idle)

        model.runTranscriptCleanup(automaticallyApply: true) { _ in
            [TranscriptCleanupEdit(startWord: 0, endWord: 0, original: "Cash", replacement: "Kash")]
        }
        let quickDeadline = Date().addingTimeInterval(3)
        while session.phase == .running && Date() < quickDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(session.phase == .applied && !session.isReviewing,
                     "Quick cleanup required manual review or failed to apply")
        precondition(model.transcriptSegments[0].text == "Kash Patel")
        precondition(model.transcriptSegments[0].timedWords[0].start == source[0].timedWords[0].start &&
                     model.transcriptSegments[0].timedWords[0].end == source[0].timedWords[0].end)
        try model.undoTranscriptCleanup()
        precondition(TranscriptCleanup.matches(source, model.transcriptSegments), "Quick cleanup could not be undone")

        model.runTranscriptCleanup(automaticallyApply: true) { _ in [] }
        let emptyDeadline = Date().addingTimeInterval(3)
        while session.phase == .running && Date() < emptyDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(session.phase == .ready && session.edits.isEmpty && session.errorText == nil,
                     "Quick cleanup with no suggestions failed")
        session.reset()
        model.runTranscriptCleanup(automaticallyApply: true) { _ in
            try await Task.sleep(nanoseconds: 10_000_000)
            return [TranscriptCleanupEdit(startWord: 0, endWord: 0, original: "Cash", replacement: "Kash")]
        }
        model.sourceSessionID = UUID()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(session.phase == .idle && TranscriptCleanup.matches(source, model.transcriptSegments),
                     "Quick cleanup applied after its source changed")
    }

    @MainActor
    private static func verify(_ mode: TranscriptDisplayMode) throws {
        let model = WorkspaceViewModel()
        let source = model.sourcePresentation
        let playback = ClipTranscriptPlaybackPresentation()
        let id = UUID()
        func segment(_ name: String) -> TranscriptSegment {
            TranscriptSegment(id: id, start: 1, end: 3, text: "shots at \(name) Patel.", timedWords: [
                TranscriptWordTiming(word: "shots", start: 1, end: 1.5),
                TranscriptWordTiming(word: "at", start: 1.5, end: 2),
                TranscriptWordTiming(word: name, start: 2, end: 2.5),
                TranscriptWordTiming(word: "Patel.", start: 2.5, end: 3)
            ])
        }
        let original = [segment("Cash")] + (1...60).map { index in
            let start = 10 + Double(index) * 10
            let text = "A later passage \(index)."
            return TranscriptSegment(start: start, end: start + 2, text: text,
                timedWords: [TranscriptWordTiming(word: text, start: start, end: start + 2)])
        }
        model.transcriptSegments = original
        playback.configure(displayRows: makeTranscriptDisplayRows(from: original, mode: mode))
        let host = NSHostingView(rootView: RetainedTranscriptStage(workspace: model, source: source, playback: playback, mode: mode).equatable())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 650, height: 500)
        defer { window.close() }
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable($0) }.first
        }
        func displayedText() -> String? {
            host.layoutSubtreeIfNeeded()
            guard let table = findTable(host), table.numberOfRows > 0,
                  let cell = table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView else { return nil }
            return cell.textField?.stringValue
        }
        func waitForText(_ expected: String?) {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if displayedText() == expected { return }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            fatalError("\(mode): sidebar showed \(displayedText() ?? "no text") instead of \(expected ?? "no text")")
        }
        waitForText("shots at Cash Patel.")
        let retainedTable = findTable(host)!
        let coordinator = retainedTable.delegate as! TranscriptTableView.Coordinator
        let unchangedRowsVersion = coordinator.rowsVersion
        model.transcriptSegments = original
        model.transcriptStatusText = "Finalizing transcript"
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        precondition(coordinator.rowsVersion == unchangedRowsVersion,
                     "Re-publishing unchanged transcript rebuilt all sidebar rows")
        retainedTable.selectRowIndexes(IndexSet(integer: 30), byExtendingSelection: false)
        retainedTable.scrollRowToVisible(30)
        let retainedScrollY = retainedTable.enclosingScrollView!.contentView.bounds.origin.y
        precondition(retainedScrollY > 0, "Scroll regression fixture did not scroll")
        let session = model.transcriptCleanup
        session.start(source: original, sourceID: model.sourceSessionID) { _ in
            [TranscriptCleanupEdit(startWord: 2, endWord: 2, original: "Cash", replacement: "Kash")]
        }
        let deadline = Date().addingTimeInterval(3)
        while session.phase == .running && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(session.phase == .ready, "Background review did not become ready")
        waitForText("shots at Cash Patel.") // Suggestions must not apply themselves.
        precondition(findTable(host) === retainedTable, "Ready results recreated the transcript table")
        precondition(retainedTable.selectedRowIndexes.contains(30), "Ready results lost transcript selection")
        precondition(abs(retainedTable.enclosingScrollView!.contentView.bounds.origin.y - retainedScrollY) < 1,
                     "Ready results moved the transcript scroll position")
        try model.applyTranscriptCleanup()
        precondition(session.phase == .applied && model.originalTranscriptSegments != nil)
        waitForText("shots at Kash Patel.")
        model.transcriptSegments = original
        waitForText("shots at Cash Patel.")
        // The second apply deliberately leaves the status unchanged.
        model.transcriptSegments = [segment("Kash")]
        waitForText("shots at Kash Patel.")
        precondition(source.transcriptSegments[0].id == id)
        precondition(source.transcriptSegments[0].timedWords.map(\.start) == original[0].timedWords.map(\.start))
        // Keep playback's old rows populated to detect an incorrect empty-state fallback.
        model.transcriptSegments = []
        waitForText(nil)

        // Source changes and retranscription invalidate work, even before its Task runs.
        session.start(source: original, sourceID: model.sourceSessionID) { _ in [] }
        model.sourceSessionID = UUID()
        precondition(session.phase == .idle)
        session.start(source: original, sourceID: model.sourceSessionID) { _ in [] }
        model.isGeneratingTranscript = true
        precondition(session.phase == .idle)
        model.isGeneratingTranscript = false
        session.start(source: original, sourceID: model.sourceSessionID) { _ in [] }
        model.transcriptSegments = original
        precondition(session.phase == .idle)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(session.phase == .idle, "Outdated request resurfaced after transcript/source change")
    }
}
