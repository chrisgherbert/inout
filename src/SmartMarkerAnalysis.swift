import Foundation

enum SmartMarkerOutputKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case markers
    case ranges
    case text

    var id: String { rawValue }

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

enum SmartMarkerSelectionStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case bestResults
    case timelineCoverage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bestResults: return "Best Results"
        case .timelineCoverage: return "Timeline Coverage"
        }
    }
}

enum SmartMarkerTextMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case timestampedList
    case document

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timestampedList: return "Timestamped List"
        case .document: return "Document"
        }
    }
}

struct SmartMarkerCustomRecipe: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var summary: String
    var instructions: String
    var outputKind: SmartMarkerOutputKind
    var defaultScope: SmartMarkerScope
    var defaultDensity: SmartMarkerDensity
    var selectionStrategy: SmartMarkerSelectionStrategy
    var maximumResults: Int
    var prefersNearbyPauses: Bool
    var textMode: SmartMarkerTextMode? = nil

    static func newRecipe() -> SmartMarkerCustomRecipe {
        SmartMarkerCustomRecipe(
            id: UUID(),
            name: "",
            summary: "",
            instructions: "",
            outputKind: .markers,
            defaultScope: .entireVideo,
            defaultDensity: .standard,
            selectionStrategy: .bestResults,
            maximumResults: 10,
            prefersNearbyPauses: false,
            textMode: nil
        )
    }

    var normalized: SmartMarkerCustomRecipe {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        result.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        result.maximumResults = min(60, max(1, maximumResults))
        if result.outputKind != .markers {
            result.prefersNearbyPauses = false
        }
        if result.outputKind == .text {
            result.textMode = result.textMode ?? .document
        } else {
            result.textMode = nil
        }
        return result
    }
}

enum SmartMarkerAnalysisRecipe: Identifiable, Equatable, Sendable {
    case builtIn(SmartMarkerRecipe)
    case custom(SmartMarkerCustomRecipe)

    static let topicChanges = SmartMarkerAnalysisRecipe.builtIn(.topicChanges)
    static let highlights = SmartMarkerAnalysisRecipe.builtIn(.highlights)
    static let adBreaks = SmartMarkerAnalysisRecipe.builtIn(.adBreaks)
    static let notableExcerpts = SmartMarkerAnalysisRecipe.builtIn(.notableExcerpts)
    static let youtubeChapters = SmartMarkerAnalysisRecipe.builtIn(.youtubeChapters)

    var id: String {
        switch self {
        case .builtIn(let recipe): return "built-in:\(recipe.rawValue)"
        case .custom(let recipe): return "custom:\(recipe.id.uuidString)"
        }
    }

    var builtInRecipe: SmartMarkerRecipe? {
        guard case .builtIn(let recipe) = self else { return nil }
        return recipe
    }

    var title: String {
        switch self {
        case .builtIn(let recipe): return recipe.title
        case .custom(let recipe): return recipe.name
        }
    }

    var description: String {
        switch self {
        case .builtIn(let recipe): return recipe.description
        case .custom(let recipe): return recipe.summary
        }
    }

    var outputKind: SmartMarkerOutputKind {
        switch self {
        case .builtIn(let recipe): return recipe.outputKind
        case .custom(let recipe): return recipe.outputKind
        }
    }

    var markerCategory: String {
        switch self {
        case .builtIn(let recipe): return recipe.markerCategory
        case .custom(let recipe): return recipe.name
        }
    }

    var resultTypeTitle: String { outputKind.title }
    var producesRanges: Bool { outputKind == .ranges }
    var isAdBreaks: Bool { builtInRecipe == .adBreaks }
    var isYouTubeChapters: Bool { builtInRecipe == .youtubeChapters }

    var textMode: SmartMarkerTextMode? {
        switch self {
        case .builtIn(.youtubeChapters): return .timestampedList
        case .builtIn: return nil
        case .custom(let recipe):
            guard recipe.outputKind == .text else { return nil }
            return recipe.textMode ?? .document
        }
    }

    var isDocumentText: Bool { textMode == .document }

    var defaultScope: SmartMarkerScope {
        switch self {
        case .builtIn(.youtubeChapters): return .entireVideo
        case .builtIn: return .selectedClip
        case .custom(let recipe): return recipe.defaultScope
        }
    }

    var defaultDensity: SmartMarkerDensity {
        switch self {
        case .builtIn: return .standard
        case .custom(let recipe): return recipe.defaultDensity
        }
    }

    var selectionStrategy: SmartMarkerSelectionStrategy {
        switch self {
        case .builtIn(.youtubeChapters): return .timelineCoverage
        case .builtIn: return .bestResults
        case .custom(let recipe): return recipe.selectionStrategy
        }
    }

    var maximumResults: Int? {
        guard case .custom(let recipe) = self else { return nil }
        return recipe.maximumResults
    }

    var prefersNearbyPauses: Bool {
        switch self {
        case .builtIn(.adBreaks): return true
        case .builtIn: return false
        case .custom(let recipe): return recipe.prefersNearbyPauses
        }
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

enum SmartMarkerScope: String, Codable, CaseIterable, Identifiable, Sendable {
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

enum SmartMarkerDensity: String, Codable, CaseIterable, Identifiable, Sendable {
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

enum SmartMarkerRefinementRole: String, Hashable, Sendable {
    case user
    case assistant
}

struct SmartMarkerRefinementMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let role: SmartMarkerRefinementRole
    let text: String

    init(
        id: UUID = UUID(),
        role: SmartMarkerRefinementRole,
        text: String
    ) {
        self.id = id
        self.role = role
        self.text = text
    }
}

struct SmartMarkerRefinementContext: Equatable, Sendable {
    let entries: [SmartMarkerTranscriptEntry]
    let scopeStart: Double
    let scopeEnd: Double
    let totalDuration: Double
}

struct SmartMarkerResultSnapshot: Equatable, Sendable {
    let suggestions: [SmartMarkerSuggestion]
    let documentText: String
    let refinementInstruction: String?

    init(
        suggestions: [SmartMarkerSuggestion],
        documentText: String,
        refinementInstruction: String? = nil
    ) {
        self.suggestions = suggestions
        self.documentText = documentText
        self.refinementInstruction = refinementInstruction
    }
}

struct SmartMarkerAnalysisConfiguration: Equatable, Sendable {
    let providerID: SmartMarkerProviderID
    let modelIdentifier: String?
    let recipe: SmartMarkerAnalysisRecipe
    let scope: SmartMarkerScope
    let density: SmartMarkerDensity
    let preferNearbyPauses: Bool
}

struct SmartMarkerAnalysisTab: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let configuration: SmartMarkerAnalysisConfiguration
    var suggestions: [SmartMarkerSuggestion]
    var documentText: String
    var refinementContext: SmartMarkerRefinementContext?
    var refinementMessages: [SmartMarkerRefinementMessage]
    var refinementRevisions: [SmartMarkerResultSnapshot]
    var currentResultRefinementInstruction: String?
    var selectedResultVersionIndex: Int
    var isRefining: Bool
    var refinementErrorText: String
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

    var supportsResultHistory: Bool {
        configuration.recipe.outputKind == .text
    }

    var latestResultVersionIndex: Int {
        refinementRevisions.count
    }

    var resolvedResultVersionIndex: Int {
        guard supportsResultHistory else { return latestResultVersionIndex }
        return min(max(0, selectedResultVersionIndex), latestResultVersionIndex)
    }

    var isViewingCurrentResult: Bool {
        resolvedResultVersionIndex == latestResultVersionIndex
    }

    var displayedResult: SmartMarkerResultSnapshot {
        let versionIndex = resolvedResultVersionIndex
        if versionIndex < refinementRevisions.count {
            return refinementRevisions[versionIndex]
        }
        return SmartMarkerResultSnapshot(
            suggestions: suggestions,
            documentText: documentText,
            refinementInstruction: currentResultRefinementInstruction
        )
    }

    mutating func selectResultVersion(_ versionIndex: Int) {
        guard supportsResultHistory else { return }
        selectedResultVersionIndex = min(max(0, versionIndex), latestResultVersionIndex)
        let displayedSuggestions = displayedResult.suggestions
        highlightedSuggestionID = displayedSuggestions.first?.id
        scrollPositionSuggestionID = displayedSuggestions.first?.id
    }

}

struct SmartMarkerTranscriptEntry: Equatable, Sendable {
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
        case .noSuggestions: return "No suitable results were generated."
        case .allSectionsBlocked:
            return "The selected AI provider couldn’t analyze any section of this transcript."
        }
    }
}

struct SmartMarkerAnalysisOutcome: Sendable {
    let suggestions: [SmartMarkerSuggestion]
    let documentText: String
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
        if configuration.recipe.isDocumentText {
            return try await analyzeDocument(
                provider: provider,
                windows: windows,
                configuration: configuration,
                progress: progress
            )
        }
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
                if configuration.recipe.selectionStrategy == .timelineCoverage {
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
                if configuration.preferNearbyPauses {
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
            documentText: "",
            skippedSectionCount: skippedSectionCount
        )
    }

    private static func analyzeDocument(
        provider: any SmartMarkerCandidateProvider,
        windows: [[SmartMarkerTranscriptEntry]],
        configuration: SmartMarkerAnalysisConfiguration,
        progress: @escaping @MainActor (
            _ completed: Int,
            _ total: Int,
            _ suggestions: [SmartMarkerSuggestion],
            _ skippedSections: Int
        ) -> Void
    ) async throws -> SmartMarkerAnalysisOutcome {
        var sections: [String] = []
        var skippedSectionCount = 0
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            do {
                let text = try await provider.generateDocument(
                    entries: window,
                    recipe: configuration.recipe
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    sections.append(text)
                }
            } catch let error as SmartMarkerProviderError {
                if case .sectionBlocked = error {
                    skippedSectionCount += 1
                } else {
                    throw error
                }
            }
            await progress(index + 1, windows.count, [], skippedSectionCount)
        }

        let documentText = sections.joined(separator: "\n\n")
        guard !documentText.isEmpty else {
            if skippedSectionCount == windows.count {
                throw SmartMarkerAnalysisError.allSectionsBlocked
            }
            throw SmartMarkerAnalysisError.noSuggestions
        }
        return SmartMarkerAnalysisOutcome(
            suggestions: [],
            documentText: documentText,
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
        if configuration.recipe.isYouTubeChapters {
            let chapterLimit = duration > 30 * 60 ? 12 : 6
            return min(calculated, chapterLimit)
        }
        if let maximumResults = configuration.recipe.maximumResults {
            return min(calculated, maximumResults)
        }
        return calculated
    }

    static func parseMarkerResponse(
        _ response: String
    ) -> [(segmentID: Int, label: String, explanation: String)] {
        SmartMarkerProviderPrompt.parseAppleResponse(response).map {
            ($0.segmentID, $0.label, $0.explanation)
        }
    }

    static func resolveRefinementSuggestions(
        _ generated: [SmartMarkerGeneratedCandidate],
        context: SmartMarkerRefinementContext,
        configuration: SmartMarkerAnalysisConfiguration
    ) throws -> [SmartMarkerSuggestion] {
        let entriesByOrdinal = Dictionary(
            uniqueKeysWithValues: context.entries.map { ($0.ordinal, $0) }
        )
        var candidates: [SmartMarkerSuggestion] = []
        for result in generated {
            guard let entry = entriesByOrdinal[result.segmentID] else { continue }
            let seconds = max(context.scopeStart, min(entry.start, context.scopeEnd))
            let endSeconds: Double?
            if configuration.recipe.producesRanges {
                guard let endSegmentID = result.endSegmentID,
                      let endEntry = entriesByOrdinal[endSegmentID] else {
                    continue
                }
                let resolvedEnd = max(
                    context.scopeStart,
                    min(endEntry.end, context.scopeEnd)
                )
                guard resolvedEnd > seconds + 0.25 else { continue }
                endSeconds = resolvedEnd
            } else {
                endSeconds = nil
            }
            candidates.append(
                SmartMarkerSuggestion(
                    sourceSegmentID: entry.segmentID,
                    seconds: seconds,
                    endSeconds: endSeconds,
                    category: configuration.recipe.markerCategory,
                    label: concise(
                        result.label,
                        fallback: configuration.recipe.markerCategory
                    ),
                    explanation: concise(
                        result.explanation,
                        fallback: "Revised from the current analysis.",
                        maximumLength: 180
                    ),
                    relevanceScore: result.relevanceScore
                )
            )
        }
        let duration = max(1, context.scopeEnd - context.scopeStart)
        let limit = targetSuggestionCount(
            duration: duration,
            configuration: configuration
        )
        let suggestions = preparedSuggestions(
            candidates,
            limit: limit,
            configuration: configuration,
            scopeStart: context.scopeStart,
            scopeEnd: context.scopeEnd
        )
        guard !suggestions.isEmpty else {
            throw SmartMarkerAnalysisError.noSuggestions
        }
        return suggestions
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
        guard configuration.recipe.selectionStrategy == .timelineCoverage else {
            return deduplicated(candidates, limit: limit)
        }

        var suggestions = chapterSuggestions(
            from: candidates,
            limit: limit,
            scopeStart: scopeStart,
            scopeEnd: scopeEnd
        )
        guard configuration.recipe.isYouTubeChapters,
              let opening = suggestions.first else {
            return suggestions
        }
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
    private var refinementTask: Task<Void, Never>?
    private var refiningTabID: UUID?

    var activeTab: SmartMarkerAnalysisTab? {
        guard let activeTabID else { return nil }
        return tabs.first(where: { $0.id == activeTabID })
    }

    var suggestions: [SmartMarkerSuggestion] {
        activeTab?.displayedResult.suggestions ?? []
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
        analyzingTabID != nil || refiningTabID != nil
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
            hasher.combine(tab.documentText)
            hasher.combine(tab.refinementMessages)
            hasher.combine(tab.refinementRevisions.count)
            hasher.combine(tab.currentResultRefinementInstruction)
            hasher.combine(tab.selectedResultVersionIndex)
            hasher.combine(tab.isRefining)
            hasher.combine(tab.refinementErrorText)
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
            documentText: "",
            refinementContext: nil,
            refinementMessages: [],
            refinementRevisions: [],
            currentResultRefinementInstruction: nil,
            selectedResultVersionIndex: 0,
            isRefining: false,
            refinementErrorText: "",
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
            updateTab(tabID) {
                $0.refinementContext = SmartMarkerRefinementContext(
                    entries: input.entries,
                    scopeStart: input.scopeStart,
                    scopeEnd: input.scopeEnd,
                    totalDuration: input.totalDuration
                )
            }
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
                        tab.documentText = outcome.documentText
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

    func selectResultVersion(_ versionIndex: Int, for tabID: UUID) {
        updateTab(tabID) { tab in
            tab.selectResultVersion(versionIndex)
        }
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if analyzingTabID == id {
            cancelAnalysis(tabID: id)
        }
        if refiningTabID == id {
            cancelRefinement(tabID: id)
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

    func refine(tabID: UUID, instruction: String) {
        let normalizedInstruction = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInstruction.isEmpty,
              analyzingTabID == nil,
              refiningTabID == nil,
              let tab = tabs.first(where: { $0.id == tabID }),
              let context = tab.refinementContext else {
            return
        }

        // Later refinement messages can contradict an earlier result selected as a branch source.
        let priorConversation = tab.isViewingCurrentResult ? tab.refinementMessages : []
        let sourceResult = tab.displayedResult
        updateTab(tabID) {
            $0.refinementMessages.append(
                SmartMarkerRefinementMessage(
                    role: .user,
                    text: normalizedInstruction
                )
            )
            $0.refinementErrorText = ""
            $0.isRefining = true
        }
        refiningTabID = tabID

        let duration = max(1, context.scopeEnd - context.scopeStart)
        let maximumResults = tab.configuration.recipe.isDocumentText
            ? 1
            : SmartMarkerAnalyzer.targetSuggestionCount(
                duration: duration,
                configuration: tab.configuration
            )
        let request = SmartMarkerRefinementRequest(
            entries: context.entries,
            recipe: tab.configuration.recipe,
            currentSuggestions: sourceResult.suggestions,
            currentDocumentText: sourceResult.documentText,
            conversation: priorConversation,
            instruction: normalizedInstruction,
            maximumResults: maximumResults
        )

        refinementTask = Task { [weak self] in
            guard let self else { return }
            do {
                let provider = try SmartMarkerProviderFactory.makeProvider(
                    id: tab.configuration.providerID,
                    modelIdentifier: tab.configuration.modelIdentifier
                )
                let response = try await provider.refine(request: request)
                try Task.checkCancellation()

                let replacementSuggestions: [SmartMarkerSuggestion]?
                let replacementDocument: String?
                if response.action == .replace {
                    if tab.configuration.recipe.isDocumentText {
                        let document = response.documentText?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard !document.isEmpty else {
                            throw SmartMarkerProviderError.invalidResponse(
                                "The AI did not return revised text."
                            )
                        }
                        replacementSuggestions = []
                        replacementDocument = document
                    } else {
                        replacementSuggestions = try SmartMarkerAnalyzer
                            .resolveRefinementSuggestions(
                                response.suggestions,
                                context: context,
                                configuration: tab.configuration
                            )
                        replacementDocument = ""
                    }
                } else {
                    replacementSuggestions = nil
                    replacementDocument = nil
                }

                let responseMessage = response.message
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let assistantMessage: String
                if !responseMessage.isEmpty {
                    assistantMessage = responseMessage
                } else if response.action == .replace {
                    assistantMessage = "Updated the results."
                } else {
                    throw SmartMarkerProviderError.invalidResponse(
                        "The AI returned an empty response."
                    )
                }
                self.updateTab(tabID) { currentTab in
                    if let replacementSuggestions, let replacementDocument {
                        currentTab.refinementRevisions.append(
                            SmartMarkerResultSnapshot(
                                suggestions: currentTab.suggestions,
                                documentText: currentTab.documentText,
                                refinementInstruction: currentTab.currentResultRefinementInstruction
                            )
                        )
                        currentTab.suggestions = replacementSuggestions
                        currentTab.documentText = replacementDocument
                        currentTab.currentResultRefinementInstruction = normalizedInstruction
                        currentTab.selectedResultVersionIndex = currentTab.latestResultVersionIndex
                        currentTab.deletedSuggestionIDs = []
                        currentTab.highlightedSuggestionID = replacementSuggestions.first?.id
                        currentTab.scrollPositionSuggestionID = replacementSuggestions.first?.id
                    }
                    currentTab.refinementMessages.append(
                        SmartMarkerRefinementMessage(
                            role: .assistant,
                            text: assistantMessage
                        )
                    )
                    currentTab.refinementErrorText = ""
                    currentTab.isRefining = false
                }
                self.finishRefinement(tabID: tabID)
            } catch is CancellationError {
                self.updateTab(tabID) { $0.isRefining = false }
                self.finishRefinement(tabID: tabID)
            } catch {
                self.updateTab(tabID) {
                    $0.refinementErrorText = error.localizedDescription
                    $0.isRefining = false
                }
                self.finishRefinement(tabID: tabID)
            }
        }
    }

    func undoLastRefinement(tabID: UUID) {
        updateTab(tabID) { tab in
            guard let previous = tab.refinementRevisions.popLast() else { return }
            tab.suggestions = previous.suggestions
            tab.documentText = previous.documentText
            tab.currentResultRefinementInstruction = previous.refinementInstruction
            tab.selectedResultVersionIndex = tab.latestResultVersionIndex
            tab.deletedSuggestionIDs = []
            tab.highlightedSuggestionID = previous.suggestions.first?.id
            tab.scrollPositionSuggestionID = previous.suggestions.first?.id
            tab.refinementErrorText = ""
        }
    }

    func cancelRefinement(tabID: UUID) {
        guard refiningTabID == tabID else { return }
        refinementTask?.cancel()
        refinementTask = nil
        refiningTabID = nil
        updateTab(tabID) { $0.isRefining = false }
    }

    private func deleteSuggestion(
        _ id: UUID,
        from tabID: UUID,
        undoManager: UndoManager?
    ) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[tabIndex].isViewingCurrentResult,
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
        if let refiningTabID {
            cancelRefinement(tabID: refiningTabID)
        }
        tabs = []
        activeTabID = nil
        showsSuggestions = false
    }

    private func uniqueTitle(for recipe: SmartMarkerAnalysisRecipe) -> String {
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

    private func finishRefinement(tabID: UUID) {
        if refiningTabID == tabID {
            refiningTabID = nil
            refinementTask = nil
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
