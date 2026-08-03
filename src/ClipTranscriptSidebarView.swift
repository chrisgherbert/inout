import SwiftUI
import AppKit

@MainActor
final class ClipTranscriptPlaybackPresentation {
    private var lastUpdateTimestamp: CFTimeInterval = 0
    private(set) var displayRows: [TranscriptDisplayRow] = []

    var activeRowID: UUID? {
        didSet {
            guard activeRowID != oldValue else { return }
            activeRowDidChange?(activeRowID)
        }
    }

    var activeRowDidChange: ((UUID?) -> Void)?

    func configure(
        displayRows: [TranscriptDisplayRow]
    ) {
        self.displayRows = displayRows
        update(time: 0, force: true)
    }

    func update(time: Double, force: Bool = false) {
        guard !PlayheadBenchmarkConfig.shared.disableTranscriptActiveRowUpdates else { return }
        let now = CACurrentMediaTime()
        guard force || (now - lastUpdateTimestamp) >= (1.0 / 12.0) else { return }

        let resolvedRowID = activeTranscriptDisplayRowID(
            at: time,
            in: displayRows
        )
        if activeRowID != resolvedRowID {
            activeRowID = resolvedRowID
            PlayheadDiagnostics.shared.noteModelWrite("transcript_active_row")
        }
        lastUpdateTimestamp = now
    }
}

struct ClipTranscriptSidebarView: View, Equatable {
    let playbackPresentation: ClipTranscriptPlaybackPresentation
    let transcriptSegments: [TranscriptSegment]
    let transcriptStatusText: String
    let canGenerateTranscript: Bool
    let isGeneratingTranscript: Bool
    let hasAudioTrack: Bool
    let isPlaying: Bool
    let isScrubbing: Bool
    let reduceTransparency: Bool
    let focusSearchFieldToken: Int
    let transcriptExportFormat: TranscriptExportFormat
    let transcriptExportLayout: TranscriptExportLayout
    let transcriptExportTimecodeStyle: TranscriptExportTimecodeStyle
    let transcriptDisplayMode: TranscriptDisplayMode
    let transcriptShowsTimecodes: Bool
    let transcriptTextSize: TranscriptTextSize
    let smartMarkerTabs: [SmartMarkerAnalysisTab]
    let activeSmartMarkerTabID: UUID?
    let showsSmartMarkerSuggestions: Bool
    let smartMarkerRevision: Int
    let generateTranscript: () -> Void
    let setTranscriptExportFormat: (TranscriptExportFormat) -> Void
    let setTranscriptExportLayout: (TranscriptExportLayout) -> Void
    let setTranscriptExportTimecodeStyle: (TranscriptExportTimecodeStyle) -> Void
    let setTranscriptDisplayMode: (TranscriptDisplayMode) -> Void
    let setTranscriptShowsTimecodes: (Bool) -> Void
    let setTranscriptTextSize: (TranscriptTextSize) -> Void
    let exportTranscript: (TranscriptExportFormat?) -> Void
    let seekToTranscriptTime: (Double) -> Void
    let playTranscriptFromTime: (Double) -> Void
    let setShowsSmartMarkerSuggestions: (Bool) -> Void
    let selectSmartMarkerTab: (UUID) -> Void
    let closeSmartMarkerTab: (UUID) -> Void
    let startNewSmartMarkerAnalysis: () -> Void
    let highlightSmartMarker: (SmartMarkerSuggestion) -> Void
    let playSmartMarker: (SmartMarkerSuggestion) -> Void
    let deleteSmartMarkerSuggestion: (UUID) -> Void
    let setSmartMarkerScrollPosition: (UUID?, UUID) -> Void
    let selectSmartMarkerResultVersion: (Int, UUID) -> Void
    let cancelSmartMarkerAnalysis: (UUID) -> Void
    let refineSmartMarkerAnalysis: (UUID, String) -> Void
    let undoSmartMarkerRefinement: (UUID) -> Void
    let onCloseTranscript: () -> Void

    @State private var searchText = ""
    @State private var currentSearchMatchID: UUID?
    @State private var requestedSearchRevealRowID: UUID?
    @State private var transcriptRows: [TranscriptDisplayRow] = []
    @State private var matchingTranscriptRowIDs: Set<UUID> = []
    @State private var matchingTranscriptRowsInOrder: [TranscriptDisplayRow] = []
    @State private var transcriptRowsVersion: Int = 0
    @State private var transcriptSearchVersion: Int = 0
    @State private var isUserScrollingTranscript = false
    @State private var transcriptControlsAvailableWidth: CGFloat = 0
    @State private var displayModeOverride: TranscriptDisplayMode?

    static func == (lhs: ClipTranscriptSidebarView, rhs: ClipTranscriptSidebarView) -> Bool {
        lhs.transcriptSegments.count == rhs.transcriptSegments.count &&
        lhs.transcriptSegments.first?.id == rhs.transcriptSegments.first?.id &&
        lhs.transcriptSegments.last?.id == rhs.transcriptSegments.last?.id &&
        lhs.transcriptStatusText == rhs.transcriptStatusText &&
        lhs.canGenerateTranscript == rhs.canGenerateTranscript &&
        lhs.isGeneratingTranscript == rhs.isGeneratingTranscript &&
        lhs.hasAudioTrack == rhs.hasAudioTrack &&
        lhs.playbackPresentation === rhs.playbackPresentation &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.isScrubbing == rhs.isScrubbing &&
        lhs.focusSearchFieldToken == rhs.focusSearchFieldToken &&
        lhs.transcriptExportFormat == rhs.transcriptExportFormat &&
        lhs.transcriptExportLayout == rhs.transcriptExportLayout &&
        lhs.transcriptExportTimecodeStyle == rhs.transcriptExportTimecodeStyle &&
        lhs.transcriptDisplayMode == rhs.transcriptDisplayMode &&
        lhs.transcriptShowsTimecodes == rhs.transcriptShowsTimecodes &&
        lhs.transcriptTextSize == rhs.transcriptTextSize &&
        lhs.reduceTransparency == rhs.reduceTransparency &&
        lhs.smartMarkerRevision == rhs.smartMarkerRevision &&
        lhs.showsSmartMarkerSuggestions == rhs.showsSmartMarkerSuggestions
    }

    private func makeTranscriptRows() -> [TranscriptDisplayRow] {
        makeTranscriptDisplayRows(from: transcriptSegments, mode: activeTranscriptDisplayMode)
    }

    private var activeTranscriptDisplayMode: TranscriptDisplayMode {
        displayModeOverride ?? transcriptDisplayMode
    }

    private var normalizedSearchText: String {
        normalizedTranscriptSearchText(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var resolvedTranscriptRows: [TranscriptDisplayRow] {
        transcriptRows.isEmpty ? playbackPresentation.displayRows : transcriptRows
    }

    private var matchingTranscriptRowCount: Int {
        matchingTranscriptRowIDs.count
    }

    private var currentSearchMatchIndex: Int? {
        guard let currentSearchMatchID else { return nil }
        return matchingTranscriptRowsInOrder.firstIndex(where: { $0.id == currentSearchMatchID })
    }

    private var currentSearchMatchDisplayText: String? {
        guard let currentSearchMatchIndex else { return nil }
        return "\(currentSearchMatchIndex + 1) of \(matchingTranscriptRowCount)"
    }

    private var displayedTranscriptRows: [TranscriptDisplayRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return resolvedTranscriptRows }
        return resolvedTranscriptRows
    }

    private var suspendsPlaybackHighlightDuringScroll: Bool {
        isUserScrollingTranscript && !normalizedSearchText.isEmpty
    }

    private var followsPlaybackRow: Bool {
        !PlayheadBenchmarkConfig.shared.disableTranscriptFollow &&
            !isScrubbing &&
            !isUserScrollingTranscript &&
            (normalizedSearchText.isEmpty || isPlaying)
    }

    private var transcriptRefreshToken: Int {
        var hasher = Hasher()
        hasher.combine(transcriptSegments.count)
        hasher.combine(transcriptSegments.first?.id)
        hasher.combine(transcriptSegments.last?.id)
        return hasher.finalize()
    }

    private var hasTranscript: Bool {
        !transcriptSegments.isEmpty
    }

    private var hasSmartMarkerActivity: Bool {
        !smartMarkerTabs.isEmpty
    }

    private var showsPlaybackIndicator: Bool {
        true
    }

    private func refreshTranscriptRows() {
        PlayheadDiagnostics.shared.noteModelWrite("transcript_sidebar_refresh")
        transcriptRows = makeTranscriptRows()
        transcriptRowsVersion &+= 1
        refreshSearchMatches()
    }

    private func refreshSearchMatches() {
        let rows = resolvedTranscriptRows
        guard !normalizedSearchText.isEmpty else {
            matchingTranscriptRowIDs = []
            matchingTranscriptRowsInOrder = []
            currentSearchMatchID = nil
            requestedSearchRevealRowID = nil
            transcriptSearchVersion &+= 1
            return
        }

        var matchingIDs = Set<UUID>()
        var matchingRows: [TranscriptDisplayRow] = []
        matchingRows.reserveCapacity(min(32, rows.count))

        for row in rows where row.normalizedText.contains(normalizedSearchText) {
            matchingIDs.insert(row.id)
            matchingRows.append(row)
        }

        matchingTranscriptRowIDs = matchingIDs
        matchingTranscriptRowsInOrder = matchingRows
        transcriptSearchVersion &+= 1

        if let currentSearchMatchID, matchingIDs.contains(currentSearchMatchID) {
            return
        }

        currentSearchMatchID = matchingRows.first?.id
    }

    private func syncCurrentSearchMatch() {
        guard !normalizedSearchText.isEmpty else {
            currentSearchMatchID = nil
            return
        }

        if let currentSearchMatchID,
           matchingTranscriptRowIDs.contains(currentSearchMatchID) {
            return
        }

        currentSearchMatchID = matchingTranscriptRowsInOrder.first?.id
    }

    private func navigateSearchMatch(direction: Int) {
        guard !matchingTranscriptRowsInOrder.isEmpty else { return }

        let targetIndex: Int
        if let currentSearchMatchIndex {
            let count = matchingTranscriptRowsInOrder.count
            targetIndex = (currentSearchMatchIndex + direction + count) % count
        } else {
            targetIndex = direction >= 0 ? 0 : max(0, matchingTranscriptRowsInOrder.count - 1)
        }

        let targetRow = matchingTranscriptRowsInOrder[targetIndex]
        currentSearchMatchID = targetRow.id
        requestSearchReveal(for: targetRow.id)
        seekToTranscriptTime(targetRow.start)
    }

    private func requestSearchReveal(for rowID: UUID) {
        requestedSearchRevealRowID = rowID
        DispatchQueue.main.async {
            if requestedSearchRevealRowID == rowID {
                requestedSearchRevealRowID = nil
            }
        }
    }

    @ViewBuilder
    private func transcriptControls(availableWidth: CGFloat) -> some View {
        let usesStackedLayout = availableWidth < 440

        if usesStackedLayout {
            VStack(alignment: .leading, spacing: 6) {
                transcriptSearchField

                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    transcriptViewOptionsButton
                    Spacer()
                        .frame(width: 8)
                    transcriptExportButton
                }
            }
        } else {
            HStack(spacing: 8) {
                transcriptSearchField
                transcriptViewOptionsButton
                transcriptExportButton
            }
        }
    }

    private var transcriptExportButton: some View {
        TranscriptExportControls(
            selectedFormat: Binding(
                get: { transcriptExportFormat },
                set: { setTranscriptExportFormat($0) }
            ),
            selectedLayout: Binding(
                get: { transcriptExportLayout },
                set: { setTranscriptExportLayout($0) }
            ),
            selectedTimecodeStyle: Binding(
                get: { transcriptExportTimecodeStyle },
                set: { setTranscriptExportTimecodeStyle($0) }
            ),
            exportTranscript: { exportTranscript(nil) }
        )
    }

    private var transcriptViewOptionsButton: some View {
        TranscriptViewOptionsButton(
            mode: activeTranscriptDisplayMode,
            showsTimecodes: transcriptShowsTimecodes,
            textSize: transcriptTextSize,
            setMode: { mode in
                displayModeOverride = mode
                setTranscriptDisplayMode(mode)
            },
            setShowsTimecodes: setTranscriptShowsTimecodes,
            setTextSize: setTranscriptTextSize
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if hasSmartMarkerActivity {
                    Picker(
                        "Sidebar",
                        selection: Binding(
                            get: { showsSmartMarkerSuggestions },
                            set: { setShowsSmartMarkerSuggestions($0) }
                        )
                    ) {
                        Text("Transcript").tag(false)
                        Text("Suggestions").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(maxWidth: 250)
                } else {
                    Text("Transcript")
                        .font(.headline)
                }
                Spacer()
                if hasTranscript && !showsSmartMarkerSuggestions {
                    Text(normalizedSearchText.isEmpty ? "\(resolvedTranscriptRows.count)" : "\(matchingTranscriptRowCount) matches")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button(action: onCloseTranscript) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide Transcript")
                .accessibilityLabel("Hide Transcript")
            }

            if showsSmartMarkerSuggestions && hasSmartMarkerActivity {
                SmartMarkerReviewView(
                    tabs: smartMarkerTabs,
                    activeTabID: activeSmartMarkerTabID,
                    onSelectTab: selectSmartMarkerTab,
                    onCloseTab: closeSmartMarkerTab,
                    onNewAnalysis: startNewSmartMarkerAnalysis,
                    onHighlight: highlightSmartMarker,
                    onPlay: playSmartMarker,
                    onDeleteSuggestion: deleteSmartMarkerSuggestion,
                    onSetScrollPosition: setSmartMarkerScrollPosition,
                    onSelectResultVersion: selectSmartMarkerResultVersion,
                    onCancelAnalysis: cancelSmartMarkerAnalysis,
                    onRefine: refineSmartMarkerAnalysis,
                    onUndoRefinement: undoSmartMarkerRefinement
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
            } else if hasTranscript {
                VStack(alignment: .leading, spacing: 6) {
                    transcriptControls(
                        availableWidth: transcriptControlsAvailableWidth > 0 ? transcriptControlsAvailableWidth : 600
                    )
                    .background(
                        GeometryReader { geometry in
                            Color.clear
                                .preference(
                                    key: TranscriptControlsWidthPreferenceKey.self,
                                    value: geometry.size.width
                                )
                        }
                    )
                    .onPreferenceChange(TranscriptControlsWidthPreferenceKey.self) { newWidth in
                        transcriptControlsAvailableWidth = newWidth
                    }

                    if !normalizedSearchText.isEmpty {
                        HStack(spacing: 8) {
                            Text(currentSearchMatchDisplayText ?? "0 of \(matchingTranscriptRowCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)

                            HStack(spacing: 4) {
                                Button {
                                    navigateSearchMatch(direction: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(matchingTranscriptRowsInOrder.isEmpty)
                                .help("Previous match")

                                Button {
                                    navigateSearchMatch(direction: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(matchingTranscriptRowsInOrder.isEmpty)
                                .help("Next match")
                            }

                            Spacer(minLength: 0)
                        }
                    }
                }

                if isGeneratingTranscript {
                    HStack(alignment: .top, spacing: 8) {
                        TranscriptGeneratingDot()
                            .padding(.top, 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Generating transcript...")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary.opacity(0.88))
                            Text("Wording and timing may shift slightly until transcription completes.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.05), lineWidth: 0.6)
                    )
                }

                TranscriptTableView(
                    rows: displayedTranscriptRows,
                    rowsVersion: transcriptRowsVersion,
                    fontSize: transcriptTextSize.fontSize,
                    displayMode: activeTranscriptDisplayMode,
                    showsTimecodes: transcriptShowsTimecodes,
                    playbackPresentation: playbackPresentation,
                    allowsPlaybackRow: !suspendsPlaybackHighlightDuringScroll,
                    followsActiveRow: followsPlaybackRow,
                    showsPlaybackIndicator: showsPlaybackIndicator && !suspendsPlaybackHighlightDuringScroll,
                    searchQuery: normalizedSearchText,
                    matchingRowIDs: matchingTranscriptRowIDs,
                    searchVersion: transcriptSearchVersion,
                    currentSearchResultRowID: currentSearchMatchID,
                    requestedSearchRevealRowID: requestedSearchRevealRowID,
                    allowsMultipleSelection: true,
                    onUserScrollActivityChanged: { active in
                        isUserScrollingTranscript = active
                    },
                    onActivateRow: { row in
                        if matchingTranscriptRowIDs.contains(row.id) {
                            currentSearchMatchID = row.id
                            requestSearchReveal(for: row.id)
                        }
                        seekToTranscriptTime(row.start)
                    },
                    onDoubleActivateRow: { row in
                        if matchingTranscriptRowIDs.contains(row.id) {
                            currentSearchMatchID = row.id
                            requestSearchReveal(for: row.id)
                        }
                        playTranscriptFromTime(row.start)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 8) {
                    if isGeneratingTranscript {
                        TranscriptGeneratingDot()
                    }
                    Text(transcriptStatusText)
                        .font(.caption)
                        .foregroundStyle(isGeneratingTranscript ? Color.primary.opacity(0.82) : Color.secondary)
                        .lineLimit(2)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(hasAudioTrack ? transcriptStatusText : "No audio track available for transcript.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if hasAudioTrack && canGenerateTranscript {
                        Button(isGeneratingTranscript ? "Generating Transcript…" : "Generate Transcript") {
                            generateTranscript()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isGeneratingTranscript)
                    } else if isGeneratingTranscript {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Generating transcript…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            refreshTranscriptRows()
        }
        .onChange(of: transcriptRefreshToken) { _ in
            refreshTranscriptRows()
        }
        .onChange(of: activeTranscriptDisplayMode) { _ in
            refreshTranscriptRows()
        }
        .onChange(of: transcriptDisplayMode) { mode in
            if displayModeOverride == mode {
                displayModeOverride = nil
            }
        }
        .onChange(of: normalizedSearchText) { _ in
            refreshSearchMatches()
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            adaptiveContainerFill(
                material: .thinMaterial,
                fallback: Color(nsColor: .controlBackgroundColor),
                reduceTransparency: reduceTransparency
            ),
            in: RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
    }
}

private struct TranscriptControlsWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension ClipTranscriptSidebarView {
    var transcriptSearchField: some View {
        TranscriptSearchField(
            text: $searchText,
            placeholder: "Search transcript",
            focusToken: focusSearchFieldToken,
            onSubmit: {
                navigateSearchMatch(direction: 1)
            }
        )
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 22)
            .layoutPriority(1)
    }
}

private struct TranscriptSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusToken: Int
    let onSubmit: () -> Void

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: TranscriptSearchField
        var lastAppliedFocusToken: Int

        init(parent: TranscriptSearchField) {
            self.parent = parent
            self.lastAppliedFocusToken = parent.focusToken
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            let value = field.stringValue
            if parent.text != value {
                parent.text = value
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField(frame: .zero)
        searchField.delegate = context.coordinator
        searchField.placeholderString = placeholder
        searchField.controlSize = .small
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.recentsAutosaveName = nil
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.parent = self

        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }

        if context.coordinator.lastAppliedFocusToken != focusToken {
            context.coordinator.lastAppliedFocusToken = focusToken
            DispatchQueue.main.async {
                guard let window = nsView.window else { return }
                if window.firstResponder !== nsView.currentEditor() {
                    window.makeFirstResponder(nsView)
                }
            }
        }
    }
}

private struct TranscriptGeneratingDot: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + (0.5 * sin(elapsed * .pi * 1.5))
            let opacity = 0.45 + (pulse * 0.45)
            let scale = 0.82 + (pulse * 0.22)

            Circle()
                .fill(Color.accentColor.opacity(opacity))
                .frame(width: 7, height: 7)
                .scaleEffect(scale)
        }
        .frame(width: 8, height: 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
