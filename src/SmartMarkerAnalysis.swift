import Foundation

enum SmartMarkerOutputKind: String, Sendable {
    case markers
    case ranges
    case text

    var title: String {
        switch self {
        case .markers: return "Markers"
        case .ranges: return "Ranges"
        case .text: return "Text"
        }
    }
}

enum SmartMarkerRecipe: String, CaseIterable, Identifiable, Sendable {
    case topicChanges
    case highlights
    case adBreaks
    case notableExcerpts
    case youtubeChapters

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topicChanges: return "Topic Changes"
        case .highlights: return "Highlights"
        case .adBreaks: return "Ad Breaks"
        case .notableExcerpts: return "Notable Excerpts"
        case .youtubeChapters: return "YouTube Chapters"
        }
    }

    var description: String {
        switch self {
        case .topicChanges:
            return "Create labeled chapters when the conversation changes direction."
        case .highlights:
            return "Find strong quotes and important moments."
        case .adBreaks:
            return "Find natural transitions with a suitable nearby audio pause."
        case .notableExcerpts:
            return "Find self-contained passages that would work as clips or quoted excerpts."
        case .youtubeChapters:
            return "Create a timestamped chapter list for a video description."
        }
    }

    var markerCategory: String {
        switch self {
        case .topicChanges: return "Topic change"
        case .highlights: return "Highlight"
        case .adBreaks: return "Possible ad break"
        case .notableExcerpts: return "Notable excerpt"
        case .youtubeChapters: return "Chapter"
        }
    }

    var outputKind: SmartMarkerOutputKind {
        switch self {
        case .topicChanges, .highlights, .adBreaks:
            return .markers
        case .notableExcerpts:
            return .ranges
        case .youtubeChapters:
            return .text
        }
    }

    var producesRanges: Bool {
        outputKind == .ranges
    }

    var resultTypeTitle: String {
        outputKind.title
    }
}

func formatSmartMarkerChapterTimestamp(_ seconds: Double) -> String {
    let totalSeconds = max(0, Int(seconds.rounded()))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let remainingSeconds = totalSeconds % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
}

func smartMarkerTextLine(for suggestion: SmartMarkerSuggestion) -> String {
    "\(formatSmartMarkerChapterTimestamp(suggestion.seconds)) \(suggestion.label)"
}

enum SmartMarkerScope: String, CaseIterable, Identifiable, Sendable {
    case selectedClip
    case entireVideo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selectedClip: return "Selected Clip"
        case .entireVideo: return "Entire Video"
        }
    }
}

enum SmartMarkerDensity: String, CaseIterable, Identifiable, Sendable {
    case fewer
    case standard
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fewer: return "Fewer"
        case .standard: return "Standard"
        case .more: return "More"
        }
    }

    var targetIntervalSeconds: Double {
        switch self {
        case .fewer: return 600
        case .standard: return 300
        case .more: return 150
        }
    }

    var perWindowLimit: Int {
        switch self {
        case .fewer: return 2
        case .standard: return 3
        case .more: return 5
        }
    }
}

struct SmartMarkerSuggestion: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let sourceSegmentID: UUID
    let seconds: Double
    let endSeconds: Double?
    let category: String
    let label: String
    let explanation: String
    let relevanceScore: Double

    init(
        id: UUID = UUID(),
        sourceSegmentID: UUID,
        seconds: Double,
        endSeconds: Double? = nil,
        category: String,
        label: String,
        explanation: String,
        relevanceScore: Double = 50
    ) {
        self.id = id
        self.sourceSegmentID = sourceSegmentID
        self.seconds = seconds
        self.endSeconds = endSeconds
        self.category = category
        self.label = label
        self.explanation = explanation
        self.relevanceScore = relevanceScore
    }

    var duration: Double? {
        guard let endSeconds else { return nil }
        return max(0, endSeconds - seconds)
    }

    var navigationSeconds: [Double] {
        guard let endSeconds, endSeconds > seconds else {
            return [seconds]
        }
        return [seconds, endSeconds]
    }
}

struct SmartMarkerAnalysisConfiguration: Equatable, Sendable {
    let providerID: SmartMarkerProviderID
    let modelIdentifier: String?
    let recipe: SmartMarkerRecipe
    let scope: SmartMarkerScope
    let density: SmartMarkerDensity
    let preferNearbyPauses: Bool
}

struct SmartMarkerAnalysisTab: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let configuration: SmartMarkerAnalysisConfiguration
    var suggestions: [SmartMarkerSuggestion]
    var deletedSuggestionIDs: Set<UUID>
    var highlightedSuggestionID: UUID?
    var scrollPositionSuggestionID: UUID?
    var isAnalyzing: Bool
    var completedWindows: Int
    var totalWindows: Int
    var skippedWindowCount: Int
    var errorText: String

    var progressText: String {
        guard isAnalyzing else { return "" }
        if totalWindows > 0 {
            return "Analyzing transcript… Section \(min(completedWindows + 1, totalWindows)) of \(totalWindows)"
        }
        return "Preparing transcript analysis…"
    }

    var warningText: String {
        guard skippedWindowCount > 0 else { return "" }
        let noun = skippedWindowCount == 1 ? "section" : "sections"
        return "\(skippedWindowCount) \(noun) couldn’t be analyzed by \(configuration.providerID.title)."
    }

}

struct SmartMarkerTranscriptEntry: Sendable {
    let ordinal: Int
    let segmentID: UUID
    let start: Double
    let end: Double
    let text: String
}

struct SmartMarkerAnalysisInput: Sendable {
    let entries: [SmartMarkerTranscriptEntry]
    let scopeStart: Double
    let scopeEnd: Double
    let totalDuration: Double
    let waveformSamples: [Double]
}

enum SmartMarkerAnalysisError: LocalizedError {
    case unavailable(String)
    case noTranscriptInScope
    case noSuggestions
    case allSectionsBlocked

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .noTranscriptInScope: return "There is no transcript in the selected range."
        case .noSuggestions: return "No suitable marker suggestions were found."
        case .allSectionsBlocked:
            return "The selected AI provider couldn’t analyze any section of this transcript."
        }
    }
}

struct SmartMarkerAnalysisOutcome: Sendable {
    let suggestions: [SmartMarkerSuggestion]
    let skippedSectionCount: Int
}

struct SmartMarkerAnalyzer {
    static func availabilityMessage(for providerID: SmartMarkerProviderID) -> String? {
        SmartMarkerProviderFactory.availabilityMessage(for: providerID)
    }

    static func makeInput(
        segments: [TranscriptSegment],
        configuration: SmartMarkerAnalysisConfiguration,
        clipStart: Double,
        clipEnd: Double,
        totalDuration: Double,
        waveformSamples: [Double]
    ) throws -> SmartMarkerAnalysisInput {
        let scopeStart = configuration.scope == .selectedClip ? clipStart : 0
        let scopeEnd = configuration.scope == .selectedClip ? clipEnd : totalDuration
        var allEntries: [SmartMarkerTranscriptEntry] = []
        var nextOrdinal = 0
        for segment in segments {
            let segmentEntries = analysisEntries(
                for: segment,
                startingOrdinal: nextOrdinal
            )
            allEntries.append(contentsOf: segmentEntries)
            nextOrdinal += segmentEntries.count
        }
        let entries = allEntries.filter {
            $0.end >= scopeStart && $0.start <= scopeEnd
        }
        guard !entries.isEmpty else {
            throw SmartMarkerAnalysisError.noTranscriptInScope
        }
        return SmartMarkerAnalysisInput(
            entries: entries,
            scopeStart: scopeStart,
            scopeEnd: scopeEnd,
            totalDuration: totalDuration,
            waveformSamples: waveformSamples
        )
    }

    static func analysisEntries(
        for segment: TranscriptSegment,
        startingOrdinal: Int
    ) -> [SmartMarkerTranscriptEntry] {
        let segmentText = normalizedAnalysisText(segment.text)
        guard !segmentText.isEmpty else { return [] }

        let words = segment.timedWords.filter {
            !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                $0.end >= $0.start
        }
        let reconstructedText = normalizedAnalysisText(
            words.map(\.word).joined(separator: " ")
        )
        guard !words.isEmpty, reconstructedText == segmentText else {
            return [
                SmartMarkerTranscriptEntry(
                    ordinal: startingOrdinal,
                    segmentID: segment.id,
                    start: segment.start,
                    end: segment.end,
                    text: segmentText
                )
            ]
        }

        var entries: [SmartMarkerTranscriptEntry] = []
        var chunk = Array(words.prefix(0))

        func flushChunk() {
            guard let first = chunk.first, let last = chunk.last else { return }
            entries.append(
                SmartMarkerTranscriptEntry(
                    ordinal: startingOrdinal + entries.count,
                    segmentID: segment.id,
                    start: max(segment.start, first.start),
                    end: min(segment.end, max(first.start + 0.05, last.end)),
                    text: normalizedAnalysisText(
                        chunk.map { $0.word }.joined(separator: " ")
                    )
                )
            )
            chunk.removeAll(keepingCapacity: true)
        }

        for word in words {
            chunk.append(word)
            guard let first = chunk.first else { continue }
            let duration = max(0, word.end - first.start)
            let endsAtBoundary = word.word.last.map {
                ".!?,;:".contains($0)
            } ?? false
            if duration >= 1.8 ||
                chunk.count >= 12 ||
                (duration >= 0.8 && endsAtBoundary) {
                flushChunk()
            }
        }
        flushChunk()

        let entryText = normalizedAnalysisText(
            entries.map(\.text).joined(separator: " ")
        )
        guard !entries.isEmpty, entryText == segmentText else {
            return [
                SmartMarkerTranscriptEntry(
                    ordinal: startingOrdinal,
                    segmentID: segment.id,
                    start: segment.start,
                    end: segment.end,
                    text: segmentText
                )
            ]
        }
        return entries
    }

    private static func normalizedAnalysisText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func analyze(
        input: SmartMarkerAnalysisInput,
        configuration: SmartMarkerAnalysisConfiguration,
        progress: @escaping @MainActor (
            _ completed: Int,
            _ total: Int,
            _ suggestions: [SmartMarkerSuggestion],
            _ skippedSections: Int
        ) -> Void
    ) async throws -> SmartMarkerAnalysisOutcome {
        let provider = try SmartMarkerProviderFactory.makeProvider(
            id: configuration.providerID,
            modelIdentifier: configuration.modelIdentifier
        )

        let windows = makeWindows(
            from: input.entries,
            tokenLimit: provider.transcriptTokenLimit
        )
        let duration = max(1, input.scopeEnd - input.scopeStart)
        let targetCount = targetSuggestionCount(
            duration: duration,
            configuration: configuration
        )
        var candidates: [SmartMarkerSuggestion] = []
        var skippedSectionCount = 0
        for (windowIndex, window) in windows.enumerated() {
            try Task.checkCancellation()
            let generated: [SmartMarkerGeneratedCandidate]
            do {
                let windowDuration = max(
                    0,
                    (window.last?.end ?? input.scopeEnd) - (window.first?.start ?? input.scopeStart)
                )
                let calculatedWindowLimit = max(
                    configuration.density.perWindowLimit,
                    min(
                        provider.maximumCandidatesPerWindow,
                        Int(ceil(windowDuration / configuration.density.targetIntervalSeconds)) + 1
                    )
                )
                let windowLimit: Int
                if configuration.recipe.outputKind == .text {
                    let candidatePoolTarget = min(
                        provider.maximumCandidatesPerWindow,
                        targetCount * 2
                    )
                    let proportionalLimit = Int(
                        ceil(Double(candidatePoolTarget) * windowDuration / duration)
                    )
                    windowLimit = min(
                        provider.maximumCandidatesPerWindow,
                        max(1, proportionalLimit)
                    )
                } else {
                    windowLimit = calculatedWindowLimit
                }
                generated = try await provider.generateCandidates(
                    entries: window,
                    recipe: configuration.recipe,
                    limit: windowLimit
                )
            } catch let error as SmartMarkerProviderError {
                switch error {
                case .sectionBlocked:
                    skippedSectionCount += 1
                    await progress(
                        windowIndex + 1,
                        windows.count,
                        preparedSuggestions(
                            candidates,
                            limit: targetCount,
                            configuration: configuration,
                            scopeStart: input.scopeStart,
                            scopeEnd: input.scopeEnd
                        ),
                        skippedSectionCount
                    )
                    continue
                default:
                    throw error
                }
            }
            let entriesByOrdinal = Dictionary(uniqueKeysWithValues: window.map { ($0.ordinal, $0) })
            for marker in generated {
                guard let entry = entriesByOrdinal[marker.segmentID] else { continue }
                let rawSeconds = max(input.scopeStart, min(entry.start, input.scopeEnd))
                let rangeEndSeconds: Double?
                if configuration.recipe.producesRanges {
                    guard let endSegmentID = marker.endSegmentID,
                          let endEntry = entriesByOrdinal[endSegmentID] else {
                        continue
                    }
                    let resolvedEnd = max(
                        input.scopeStart,
                        min(endEntry.end, input.scopeEnd)
                    )
                    guard resolvedEnd > rawSeconds + 0.25 else { continue }
                    rangeEndSeconds = resolvedEnd
                } else {
                    rangeEndSeconds = nil
                }
                let resolvedSeconds: Double
                if configuration.recipe == .adBreaks, configuration.preferNearbyPauses {
                    resolvedSeconds = quietPoint(
                        near: rawSeconds,
                        samples: input.waveformSamples,
                        duration: input.totalDuration
                    ) ?? rawSeconds
                } else {
                    resolvedSeconds = rawSeconds
                }
                let label = concise(marker.label, fallback: configuration.recipe.markerCategory)
                let explanation = concise(
                    marker.explanation,
                    fallback: "Suggested from the transcript near this point.",
                    maximumLength: 180
                )
                candidates.append(
                    SmartMarkerSuggestion(
                        sourceSegmentID: entry.segmentID,
                        seconds: resolvedSeconds,
                        endSeconds: rangeEndSeconds,
                        category: configuration.recipe.markerCategory,
                        label: label,
                        explanation: explanation,
                        relevanceScore: marker.relevanceScore
                    )
                )
            }
            await progress(
                windowIndex + 1,
                windows.count,
                preparedSuggestions(
                    candidates,
                    limit: targetCount,
                    configuration: configuration,
                    scopeStart: input.scopeStart,
                    scopeEnd: input.scopeEnd
                ),
                skippedSectionCount
            )
        }

        let suggestions = preparedSuggestions(
            candidates,
            limit: targetCount,
            configuration: configuration,
            scopeStart: input.scopeStart,
            scopeEnd: input.scopeEnd
        )
        guard !suggestions.isEmpty else {
            if skippedSectionCount == windows.count {
                throw SmartMarkerAnalysisError.allSectionsBlocked
            }
            throw SmartMarkerAnalysisError.noSuggestions
        }
        return SmartMarkerAnalysisOutcome(
            suggestions: suggestions,
            skippedSectionCount: skippedSectionCount
        )
    }

    static func makeWindows(
        from entries: [SmartMarkerTranscriptEntry],
        tokenLimit: Int = 2_800,
        overlapCount: Int = 6
    ) -> [[SmartMarkerTranscriptEntry]] {
        guard !entries.isEmpty else { return [] }
        var windows: [[SmartMarkerTranscriptEntry]] = []
        var start = 0

        while start < entries.count {
            var end = start
            var tokens = 0
            while end < entries.count {
                let entry = entries[end]
                let nextCount = estimatedTokenCount("[\(entry.ordinal)] \(entry.text)\n")
                if end > start, tokens + nextCount > tokenLimit {
                    break
                }
                tokens += nextCount
                end += 1
            }
            windows.append(Array(entries[start..<end]))
            guard end < entries.count else { break }
            start = max(start + 1, end - overlapCount)
        }
        return windows
    }

    static func estimatedTokenCount(_ text: String) -> Int {
        var tokenCount = 0
        var latinCharacterCount = 0

        func flushLatinCharacters() {
            guard latinCharacterCount > 0 else { return }
            // Apple documents roughly three to four Latin characters per token.
            tokenCount += Int(ceil(Double(latinCharacterCount) / 3.0))
            latinCharacterCount = 0
        }

        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                latinCharacterCount += 1
            } else {
                flushLatinCharacters()
                // CJK and other multibyte text can consume approximately one token per character.
                tokenCount += 1
            }
        }
        flushLatinCharacters()
        return max(1, tokenCount)
    }

    static func targetSuggestionCount(
        duration: Double,
        configuration: SmartMarkerAnalysisConfiguration
    ) -> Int {
        let calculated = max(
            1,
            min(60, Int(ceil(duration / configuration.density.targetIntervalSeconds)))
        )
        guard configuration.recipe == .youtubeChapters else {
            return calculated
        }
        let chapterLimit = duration > 30 * 60 ? 12 : 6
        return min(calculated, chapterLimit)
    }

    static func parseMarkerResponse(
        _ response: String
    ) -> [(segmentID: Int, label: String, explanation: String)] {
        SmartMarkerProviderPrompt.parseAppleResponse(response).map {
            ($0.segmentID, $0.label, $0.explanation)
        }
    }

    private static func concise(
        _ value: String,
        fallback: String,
        maximumLength: Int = 72
    ) -> String {
        let normalized = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = normalized.isEmpty ? fallback : normalized
        guard resolved.count > maximumLength else { return resolved }
        return String(resolved.prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func deduplicated(
        _ candidates: [SmartMarkerSuggestion],
        limit: Int
    ) -> [SmartMarkerSuggestion] {
        let sorted = candidates.sorted {
            if abs($0.relevanceScore - $1.relevanceScore) > 0.001 {
                return $0.relevanceScore > $1.relevanceScore
            }
            return $0.seconds < $1.seconds
        }
        var accepted: [SmartMarkerSuggestion] = []
        for candidate in sorted {
            let isDuplicate = accepted.contains {
                if candidate.endSeconds != nil || $0.endSeconds != nil {
                    return abs($0.seconds - candidate.seconds) < 8
                }
                return $0.sourceSegmentID == candidate.sourceSegmentID ||
                    abs($0.seconds - candidate.seconds) < 8
            }
            if !isDuplicate {
                accepted.append(candidate)
            }
        }

        return Array(accepted.prefix(limit)).sorted { $0.seconds < $1.seconds }
    }

    static func preparedSuggestions(
        _ candidates: [SmartMarkerSuggestion],
        limit: Int,
        configuration: SmartMarkerAnalysisConfiguration,
        scopeStart: Double,
        scopeEnd: Double
    ) -> [SmartMarkerSuggestion] {
        guard configuration.recipe.outputKind == .text else {
            return deduplicated(candidates, limit: limit)
        }

        var suggestions = chapterSuggestions(
            from: candidates,
            limit: limit,
            scopeStart: scopeStart,
            scopeEnd: scopeEnd
        )
        guard let opening = suggestions.first else { return [] }
        suggestions[0] = SmartMarkerSuggestion(
            id: opening.id,
            sourceSegmentID: opening.sourceSegmentID,
            seconds: scopeStart,
            endSeconds: opening.endSeconds,
            category: opening.category,
            label: opening.label,
            explanation: opening.explanation,
            relevanceScore: opening.relevanceScore
        )
        return suggestions
    }

    private static func chapterSuggestions(
        from candidates: [SmartMarkerSuggestion],
        limit: Int,
        scopeStart: Double,
        scopeEnd: Double
    ) -> [SmartMarkerSuggestion] {
        guard limit > 0 else { return [] }
        let pool = deduplicated(candidates, limit: candidates.count)
        guard pool.count > limit else { return pool }

        let bucketCount = min(3, limit)
        let duration = max(1, scopeEnd - scopeStart)
        var quotas = Array(repeating: limit / bucketCount, count: bucketCount)
        for index in 0..<(limit % bucketCount) {
            quotas[index] += 1
        }

        // Preserve the model's earliest boundary as the opening chapter.
        let opening = pool[0]
        var selected = [opening]
        var selectedIDs = Set([opening.id])
        quotas[0] = max(0, quotas[0] - 1)

        for bucket in 0..<bucketCount where quotas[bucket] > 0 {
            let bucketCandidates = pool
                .filter { candidate in
                    guard !selectedIDs.contains(candidate.id) else { return false }
                    let progress = max(
                        0,
                        min(0.999_999, (candidate.seconds - scopeStart) / duration)
                    )
                    return min(bucketCount - 1, Int(progress * Double(bucketCount))) == bucket
                }
                .sorted(by: suggestionQualityOrder)
            for candidate in bucketCandidates.prefix(quotas[bucket]) {
                selected.append(candidate)
                selectedIDs.insert(candidate.id)
            }
        }

        if selected.count < limit {
            let remaining = pool
                .filter { !selectedIDs.contains($0.id) }
                .sorted(by: suggestionQualityOrder)
            selected.append(contentsOf: remaining.prefix(limit - selected.count))
        }

        return selected.sorted { $0.seconds < $1.seconds }
    }

    private static func suggestionQualityOrder(
        _ lhs: SmartMarkerSuggestion,
        _ rhs: SmartMarkerSuggestion
    ) -> Bool {
        if abs(lhs.relevanceScore - rhs.relevanceScore) > 0.001 {
            return lhs.relevanceScore > rhs.relevanceScore
        }
        return lhs.seconds < rhs.seconds
    }

    private static func quietPoint(
        near seconds: Double,
        samples: [Double],
        duration: Double
    ) -> Double? {
        guard samples.count > 2, duration > 0 else { return nil }
        let samplesPerSecond = Double(samples.count - 1) / duration
        let center = Int((seconds * samplesPerSecond).rounded())
        let radius = max(1, Int((2.5 * samplesPerSecond).rounded()))
        let lower = max(0, center - radius)
        let upper = min(samples.count - 1, center + radius)
        guard lower <= upper else { return nil }

        var bestIndex = center
        var bestAmplitude = Double.greatestFiniteMagnitude
        for index in lower...upper where samples[index] < bestAmplitude {
            bestAmplitude = samples[index]
            bestIndex = index
        }
        guard bestAmplitude <= 0.08 else { return nil }
        return Double(bestIndex) / samplesPerSecond
    }

}

@MainActor
final class SmartMarkerPresentationModel: ObservableObject {
    @Published private(set) var tabs: [SmartMarkerAnalysisTab] = []
    @Published private(set) var activeTabID: UUID?
    @Published var showsSuggestions = false

    private var analysisTask: Task<Void, Never>?
    private var analyzingTabID: UUID?

    var activeTab: SmartMarkerAnalysisTab? {
        guard let activeTabID else { return nil }
        return tabs.first(where: { $0.id == activeTabID })
    }

    var suggestions: [SmartMarkerSuggestion] {
        activeTab?.suggestions ?? []
    }

    var timelineSuggestions: [SmartMarkerSuggestion] {
        guard activeTab?.configuration.recipe.outputKind != .text else {
            return []
        }
        return suggestions
    }

    var highlightedSuggestionID: UUID? {
        get { activeTab?.highlightedSuggestionID }
        set {
            guard let activeTabID else { return }
            updateTab(activeTabID) {
                $0.highlightedSuggestionID = newValue
            }
        }
    }

    var isAnalyzing: Bool {
        analyzingTabID != nil
    }

    var progressText: String {
        activeTab?.progressText ?? ""
    }

    var warningText: String {
        activeTab?.warningText ?? ""
    }

    var errorText: String {
        activeTab?.errorText ?? ""
    }

    var revision: Int {
        var hasher = Hasher()
        hasher.combine(activeTabID)
        for tab in tabs {
            hasher.combine(tab.id)
            hasher.combine(tab.title)
            hasher.combine(tab.suggestions)
            hasher.combine(tab.highlightedSuggestionID)
            hasher.combine(tab.isAnalyzing)
            hasher.combine(tab.completedWindows)
            hasher.combine(tab.totalWindows)
            hasher.combine(tab.skippedWindowCount)
            hasher.combine(tab.errorText)
        }
        hasher.combine(showsSuggestions)
        return hasher.finalize()
    }

    func start(
        segments: [TranscriptSegment],
        configuration: SmartMarkerAnalysisConfiguration,
        clipStart: Double,
        clipEnd: Double,
        totalDuration: Double,
        waveformSamples: [Double]
    ) {
        guard !isAnalyzing else { return }

        let tabID = UUID()
        let title = uniqueTitle(for: configuration.recipe)
        var newTab = SmartMarkerAnalysisTab(
            id: tabID,
            title: title,
            configuration: configuration,
            suggestions: [],
            deletedSuggestionIDs: [],
            highlightedSuggestionID: nil,
            scrollPositionSuggestionID: nil,
            isAnalyzing: true,
            completedWindows: 0,
            totalWindows: 0,
            skippedWindowCount: 0,
            errorText: ""
        )
        tabs.append(newTab)
        activeTabID = tabID
        analyzingTabID = tabID
        showsSuggestions = true

        do {
            let input = try SmartMarkerAnalyzer.makeInput(
                segments: segments,
                configuration: configuration,
                clipStart: clipStart,
                clipEnd: clipEnd,
                totalDuration: totalDuration,
                waveformSamples: waveformSamples
            )
            newTab.totalWindows = SmartMarkerAnalyzer.makeWindows(
                from: input.entries,
                tokenLimit: SmartMarkerProviderFactory.transcriptTokenLimit(
                    for: configuration.providerID
                )
            ).count
            updateTab(tabID) {
                $0.totalWindows = newTab.totalWindows
            }
            analysisTask = Task { [weak self] in
                do {
                    let outcome = try await SmartMarkerAnalyzer.analyze(
                        input: input,
                        configuration: configuration
                    ) { completed, total, partialSuggestions, skippedSections in
                        guard let self else { return }
                        self.updateTab(tabID) { tab in
                            tab.completedWindows = completed
                            tab.totalWindows = total
                            tab.skippedWindowCount = skippedSections
                            let visibleSuggestions = partialSuggestions.filter {
                                !tab.deletedSuggestionIDs.contains($0.id)
                            }
                            tab.suggestions = visibleSuggestions
                            let currentIDs = Set(visibleSuggestions.map(\.id))
                            if tab.highlightedSuggestionID.map({ !currentIDs.contains($0) }) ?? true {
                                tab.highlightedSuggestionID = visibleSuggestions.first?.id
                            }
                        }
                    }
                    guard !Task.isCancelled, let self else { return }
                    self.updateTab(tabID) { tab in
                        let visibleSuggestions = outcome.suggestions.filter {
                            !tab.deletedSuggestionIDs.contains($0.id)
                        }
                        tab.suggestions = visibleSuggestions
                        tab.skippedWindowCount = outcome.skippedSectionCount
                        let resultIDs = Set(visibleSuggestions.map(\.id))
                        if tab.highlightedSuggestionID.map({ !resultIDs.contains($0) }) ?? true {
                            tab.highlightedSuggestionID = visibleSuggestions.first?.id
                        }
                        tab.isAnalyzing = false
                    }
                    self.finishAnalysis(tabID: tabID)
                } catch is CancellationError {
                    self?.updateTab(tabID) { $0.isAnalyzing = false }
                    self?.finishAnalysis(tabID: tabID)
                } catch {
                    guard let self else { return }
                    self.updateTab(tabID) {
                        $0.errorText = error.localizedDescription
                        $0.isAnalyzing = false
                    }
                    self.finishAnalysis(tabID: tabID)
                }
            }
        } catch {
            updateTab(tabID) {
                $0.errorText = error.localizedDescription
                $0.isAnalyzing = false
            }
            finishAnalysis(tabID: tabID)
        }
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        showsSuggestions = true
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if analyzingTabID == id {
            cancelAnalysis(tabID: id)
        }
        let wasActive = activeTabID == id
        tabs.remove(at: index)
        if wasActive {
            if tabs.isEmpty {
                activeTabID = nil
                showsSuggestions = false
            } else {
                activeTabID = tabs[min(index, tabs.count - 1)].id
            }
        }
    }

    func deleteSuggestion(_ id: UUID, undoManager: UndoManager?) {
        guard let activeTabID else { return }
        deleteSuggestion(id, from: activeTabID, undoManager: undoManager)
    }

    func cancelAnalysis(tabID: UUID) {
        guard analyzingTabID == tabID else { return }
        analysisTask?.cancel()
        analysisTask = nil
        analyzingTabID = nil
        updateTab(tabID) {
            $0.isAnalyzing = false
        }
    }

    private func deleteSuggestion(
        _ id: UUID,
        from tabID: UUID,
        undoManager: UndoManager?
    ) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }),
              let suggestionIndex = tabs[tabIndex].suggestions.firstIndex(where: { $0.id == id }) else {
            return
        }
        let suggestion = tabs[tabIndex].suggestions[suggestionIndex]
        removeSuggestion(id, from: tabID)
        undoManager?.registerUndo(withTarget: self) { model in
            model.restoreSuggestion(
                suggestion,
                at: suggestionIndex,
                in: tabID,
                undoManager: undoManager
            )
        }
        undoManager?.setActionName("Delete Suggestion")
    }

    func setScrollPosition(_ suggestionID: UUID?, for tabID: UUID) {
        updateTab(tabID) {
            $0.scrollPositionSuggestionID = suggestionID
        }
    }

    func cancelActiveAnalysis() {
        guard let analyzingTabID else { return }
        cancelAnalysis(tabID: analyzingTabID)
    }

    func reset() {
        cancelActiveAnalysis()
        tabs = []
        activeTabID = nil
        showsSuggestions = false
    }

    private func uniqueTitle(for recipe: SmartMarkerRecipe) -> String {
        let base = recipe.title
        let existing = Set(tabs.map(\.title))
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private func updateTab(_ id: UUID, update: (inout SmartMarkerAnalysisTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = tabs[index]
        update(&tab)
        tabs[index] = tab
    }

    private func finishAnalysis(tabID: UUID) {
        if analyzingTabID == tabID {
            analyzingTabID = nil
            analysisTask = nil
        }
    }

    private func removeSuggestion(_ id: UUID, from tabID: UUID) {
        updateTab(tabID) { tab in
            tab.deletedSuggestionIDs.insert(id)
            tab.suggestions.removeAll { $0.id == id }
            if tab.highlightedSuggestionID == id {
                tab.highlightedSuggestionID = tab.suggestions.first?.id
            }
            if tab.scrollPositionSuggestionID == id {
                tab.scrollPositionSuggestionID = tab.highlightedSuggestionID
            }
        }
    }

    private func restoreSuggestion(
        _ suggestion: SmartMarkerSuggestion,
        at index: Int,
        in tabID: UUID,
        undoManager: UndoManager?
    ) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        updateTab(tabID) { tab in
            tab.deletedSuggestionIDs.remove(suggestion.id)
            let insertionIndex = min(max(0, index), tab.suggestions.count)
            tab.suggestions.insert(suggestion, at: insertionIndex)
        }
        undoManager?.registerUndo(withTarget: self) { model in
            model.deleteSuggestion(
                suggestion.id,
                from: tabID,
                undoManager: undoManager
            )
        }
        undoManager?.setActionName("Delete Suggestion")
    }
}
