import SwiftUI

struct ClipTranscriptSidebarView: View, Equatable {
    let transcriptSegments: [TranscriptSegment]
    let transcriptStatusText: String
    let canGenerateTranscript: Bool
    let isGeneratingTranscript: Bool
    let hasAudioTrack: Bool
    let currentTimeSeconds: Double
    let isScrubbing: Bool
    let reduceTransparency: Bool
    let focusSearchFieldToken: Int
    let generateTranscript: () -> Void
    let seekToTranscriptTime: (Double) -> Void
    let playTranscriptFromTime: (Double) -> Void

    @State private var searchText = ""
    @State private var currentSearchMatchID: UUID?
    @State private var requestedSearchRevealRowID: UUID?
    @State private var transcriptRows: [TranscriptDisplayRow] = []
    @State private var matchingTranscriptRowIDs: Set<UUID> = []
    @State private var matchingTranscriptRowsInOrder: [TranscriptDisplayRow] = []
    @State private var transcriptRowsVersion: Int = 0
    @State private var transcriptSearchVersion: Int = 0
    @State private var settledCurrentTimeSeconds: Double = 0
    @FocusState private var isSearchFieldFocused: Bool

    static func == (lhs: ClipTranscriptSidebarView, rhs: ClipTranscriptSidebarView) -> Bool {
        lhs.transcriptSegments.count == rhs.transcriptSegments.count &&
        lhs.transcriptSegments.first?.id == rhs.transcriptSegments.first?.id &&
        lhs.transcriptSegments.last?.id == rhs.transcriptSegments.last?.id &&
        lhs.transcriptStatusText == rhs.transcriptStatusText &&
        lhs.canGenerateTranscript == rhs.canGenerateTranscript &&
        lhs.isGeneratingTranscript == rhs.isGeneratingTranscript &&
        lhs.hasAudioTrack == rhs.hasAudioTrack &&
        lhs.currentTimeSeconds == rhs.currentTimeSeconds &&
        lhs.isScrubbing == rhs.isScrubbing &&
        lhs.focusSearchFieldToken == rhs.focusSearchFieldToken &&
        lhs.reduceTransparency == rhs.reduceTransparency
    }

    private func makeTranscriptRows() -> [TranscriptDisplayRow] {
        transcriptSegments.map { segment in
            TranscriptDisplayRow(
                id: segment.id,
                start: segment.start,
                startLabel: formatSeconds(segment.start),
                text: segment.text,
                normalizedText: normalizedTranscriptSearchText(segment.text)
            )
        }
    }

    private var normalizedSearchText: String {
        normalizedTranscriptSearchText(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var resolvedTranscriptRows: [TranscriptDisplayRow] {
        if transcriptRows.isEmpty && !transcriptSegments.isEmpty {
            return makeTranscriptRows()
        }
        return transcriptRows
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

    private var activeTranscriptSegmentID: UUID? {
        guard !transcriptSegments.isEmpty else { return nil }
        var low = 0
        var high = transcriptSegments.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let segment = transcriptSegments[mid]
            if settledCurrentTimeSeconds < segment.start {
                high = mid - 1
            } else if settledCurrentTimeSeconds >= segment.end {
                low = mid + 1
            } else {
                return segment.id
            }
        }

        if high >= 0, high < transcriptSegments.count, settledCurrentTimeSeconds >= transcriptSegments[high].start {
            return transcriptSegments[high].id
        }
        return nil
    }


    private var hasTranscript: Bool {
        !transcriptSegments.isEmpty
    }

    private var showsPlaybackIndicator: Bool {
        true
    }

    private func refreshTranscriptRows() {
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
        requestedSearchRevealRowID = targetRow.id
        seekToTranscriptTime(targetRow.start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                if hasTranscript {
                    Text(normalizedSearchText.isEmpty ? "\(resolvedTranscriptRows.count)" : "\(matchingTranscriptRowCount) matches")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if hasTranscript {
                HStack(spacing: 8) {
                    TextField("Search transcript", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .focused($isSearchFieldFocused)
                        .onSubmit {
                            navigateSearchMatch(direction: 1)
                        }

                    if !normalizedSearchText.isEmpty {
                        Text(currentSearchMatchDisplayText ?? "0 of \(matchingTranscriptRowCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 54, alignment: .trailing)

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
                    }
                }

                TranscriptTableView(
                    rows: displayedTranscriptRows,
                    rowsVersion: transcriptRowsVersion,
                    fontSize: 13,
                    activeRowID: activeTranscriptSegmentID,
                    followsActiveRow: !isScrubbing,
                    showsPlaybackIndicator: showsPlaybackIndicator,
                    searchQuery: normalizedSearchText,
                    matchingRowIDs: matchingTranscriptRowIDs,
                    searchVersion: transcriptSearchVersion,
                    currentSearchResultRowID: currentSearchMatchID,
                    requestedSearchRevealRowID: requestedSearchRevealRowID,
                    allowsMultipleSelection: false,
                    onActivateRow: { row in
                        if matchingTranscriptRowIDs.contains(row.id) {
                            currentSearchMatchID = row.id
                            requestedSearchRevealRowID = row.id
                        }
                        seekToTranscriptTime(row.start)
                    },
                    onDoubleActivateRow: { row in
                        if matchingTranscriptRowIDs.contains(row.id) {
                            currentSearchMatchID = row.id
                            requestedSearchRevealRowID = row.id
                        }
                        playTranscriptFromTime(row.start)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(transcriptStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
            settledCurrentTimeSeconds = currentTimeSeconds
        }
        .onChange(of: focusSearchFieldToken) { _ in
            isSearchFieldFocused = true
        }
        .onChange(of: transcriptSegments.count) { _ in
            refreshTranscriptRows()
        }
        .onChange(of: normalizedSearchText) { _ in
            refreshSearchMatches()
        }
        .onChange(of: currentTimeSeconds) { newValue in
            guard !isScrubbing else { return }
            settledCurrentTimeSeconds = newValue
        }
        .onChange(of: isScrubbing) { newValue in
            if !newValue {
                settledCurrentTimeSeconds = currentTimeSeconds
            }
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
