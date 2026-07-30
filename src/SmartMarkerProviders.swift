import Foundation
import FoundationModels

enum SmartMarkerProviderID: String, CaseIterable, Identifiable, Sendable {
    case appleIntelligence
    case openAI
    case claude
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .openAI: return "OpenAI"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }

    var detail: String {
        switch self {
        case .appleIntelligence:
            return "Runs privately on this Mac."
        case .openAI:
            return "Sends transcript text to OpenAI using your API key."
        case .claude:
            return "Sends transcript text to Anthropic using your API key."
        case .gemini:
            return "Sends transcript text to Google using your Gemini API key."
        }
    }
}

enum SmartMarkerPreferences {
    static let providerKey = "prefs.smartMarkerProvider"
    static let openAIModelKey = "prefs.smartMarkerOpenAIModel"
    static let openAIModelCatalogKey = "prefs.smartMarkerOpenAIModelCatalog"
    static let openAIModelCatalogDateKey = "prefs.smartMarkerOpenAIModelCatalogDate"
    static let openAIKeychainAccount = "openai-api-key"
    static let defaultOpenAIModel = "chat-latest"
    static let claudeModelKey = "prefs.smartMarkerClaudeModel"
    static let claudeModelCatalogKey = "prefs.smartMarkerClaudeModelCatalog"
    static let claudeModelCatalogDateKey = "prefs.smartMarkerClaudeModelCatalogDate"
    static let claudeKeychainAccount = "anthropic-api-key"
    static let defaultClaudeModel = "claude-sonnet-5"
    static let geminiModelKey = "prefs.smartMarkerGeminiModel"
    static let geminiModelCatalogKey = "prefs.smartMarkerGeminiModelCatalog"
    static let geminiModelCatalogDateKey = "prefs.smartMarkerGeminiModelCatalogDate"
    static let geminiKeychainAccount = "gemini-api-key"
    static let defaultGeminiModel = "gemini-3.6-flash"

    static var providerID: SmartMarkerProviderID {
        get {
            guard let raw = UserDefaults.standard.string(forKey: providerKey),
                  let provider = SmartMarkerProviderID(rawValue: raw) else {
                return .appleIntelligence
            }
            return provider
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: providerKey)
        }
    }

    static var openAIModel: String {
        get {
            let stored = UserDefaults.standard.string(forKey: openAIModelKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultOpenAIModel : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(
                trimmed.isEmpty ? defaultOpenAIModel : trimmed,
                forKey: openAIModelKey
            )
        }
    }

    static var hasOpenAIKey: Bool {
        SecureCredentialStore.value(for: openAIKeychainAccount) != nil
    }

    static var claudeModel: String {
        get { storedModel(forKey: claudeModelKey, defaultValue: defaultClaudeModel) }
        set { storeModel(newValue, forKey: claudeModelKey, defaultValue: defaultClaudeModel) }
    }

    static var hasClaudeKey: Bool {
        SecureCredentialStore.value(for: claudeKeychainAccount) != nil
    }

    static var geminiModel: String {
        get { storedModel(forKey: geminiModelKey, defaultValue: defaultGeminiModel) }
        set { storeModel(newValue, forKey: geminiModelKey, defaultValue: defaultGeminiModel) }
    }

    static var hasGeminiKey: Bool {
        SecureCredentialStore.value(for: geminiKeychainAccount) != nil
    }

    static var cachedOpenAIModelIDs: [String] {
        UserDefaults.standard.stringArray(forKey: openAIModelCatalogKey) ?? []
    }

    static var openAIModelCatalogNeedsRefresh: Bool {
        guard let date = UserDefaults.standard.object(
            forKey: openAIModelCatalogDateKey
        ) as? Date else {
            return true
        }
        return Date().timeIntervalSince(date) > 24 * 60 * 60
    }

    static func cacheOpenAIModelIDs(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: openAIModelCatalogKey)
        UserDefaults.standard.set(Date(), forKey: openAIModelCatalogDateKey)
    }

    static func clearOpenAIModelCatalog() {
        UserDefaults.standard.removeObject(forKey: openAIModelCatalogKey)
        UserDefaults.standard.removeObject(forKey: openAIModelCatalogDateKey)
    }

    static var cachedClaudeModelIDs: [String] {
        UserDefaults.standard.stringArray(forKey: claudeModelCatalogKey) ?? []
    }

    static var claudeModelCatalogNeedsRefresh: Bool {
        modelCatalogNeedsRefresh(dateKey: claudeModelCatalogDateKey)
    }

    static func cacheClaudeModelIDs(_ ids: [String]) {
        cacheModelIDs(ids, catalogKey: claudeModelCatalogKey, dateKey: claudeModelCatalogDateKey)
    }

    static func clearClaudeModelCatalog() {
        clearModelCatalog(catalogKey: claudeModelCatalogKey, dateKey: claudeModelCatalogDateKey)
    }

    static var cachedGeminiModelIDs: [String] {
        UserDefaults.standard.stringArray(forKey: geminiModelCatalogKey) ?? []
    }

    static var geminiModelCatalogNeedsRefresh: Bool {
        modelCatalogNeedsRefresh(dateKey: geminiModelCatalogDateKey)
    }

    static func cacheGeminiModelIDs(_ ids: [String]) {
        cacheModelIDs(ids, catalogKey: geminiModelCatalogKey, dateKey: geminiModelCatalogDateKey)
    }

    static func clearGeminiModelCatalog() {
        clearModelCatalog(catalogKey: geminiModelCatalogKey, dateKey: geminiModelCatalogDateKey)
    }

    static func model(for provider: SmartMarkerProviderID) -> String? {
        switch provider {
        case .appleIntelligence: return nil
        case .openAI: return openAIModel
        case .claude: return claudeModel
        case .gemini: return geminiModel
        }
    }

    private static func storedModel(forKey key: String, defaultValue: String) -> String {
        let stored = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultValue : stored
    }

    private static func storeModel(_ value: String, forKey key: String, defaultValue: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed.isEmpty ? defaultValue : trimmed, forKey: key)
    }

    private static func modelCatalogNeedsRefresh(dateKey: String) -> Bool {
        guard let date = UserDefaults.standard.object(forKey: dateKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(date) > 24 * 60 * 60
    }

    private static func cacheModelIDs(_ ids: [String], catalogKey: String, dateKey: String) {
        UserDefaults.standard.set(ids, forKey: catalogKey)
        UserDefaults.standard.set(Date(), forKey: dateKey)
    }

    private static func clearModelCatalog(catalogKey: String, dateKey: String) {
        UserDefaults.standard.removeObject(forKey: catalogKey)
        UserDefaults.standard.removeObject(forKey: dateKey)
    }
}

struct SmartMarkerModelOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let isRecommended: Bool
}

enum SmartMarkerOpenAIModelCatalog {
    private static let recommended: [(id: String, title: String, detail: String)] = [
        ("gpt-5.6-sol", "GPT-5.6 Sol", "Highest quality for complex analysis."),
        ("gpt-5.6-terra", "GPT-5.6 Terra", "Balances quality, speed, and cost."),
        ("gpt-5.6-luna", "GPT-5.6 Luna", "Fastest and lowest-cost current option."),
        ("chat-latest", "Chat Latest", "Tracks OpenAI's latest ChatGPT-style API model.")
    ]

    static func options(from modelIDs: [String]) -> [SmartMarkerModelOption] {
        let available = Set(modelIDs.filter(isCompatibleAlias))
        let recommendedIDs = Set(recommended.map(\.id))
        let recommendedOptions: [SmartMarkerModelOption] = recommended.compactMap { model in
            guard available.contains(model.id) else { return nil }
            return SmartMarkerModelOption(
                id: model.id,
                title: model.title,
                detail: model.detail,
                isRecommended: true
            )
        }
        let otherOptions = available
            .subtracting(recommendedIDs)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map {
                SmartMarkerModelOption(
                    id: $0,
                    title: $0,
                    detail: "Available to this API key.",
                    isRecommended: false
                )
            }
        return recommendedOptions + otherOptions
    }

    static func isCompatibleAlias(_ id: String) -> Bool {
        let normalized = id.lowercased()
        guard normalized == "chat-latest" ||
                normalized.hasPrefix("gpt-5") ||
                normalized.hasPrefix("gpt-4.1") ||
                normalized.hasPrefix("gpt-4o") else {
            return false
        }
        let unsupportedKinds = [
            "audio",
            "codex",
            "image",
            "instruct",
            "moderation",
            "realtime",
            "search",
            "transcribe",
            "tts"
        ]
        guard !unsupportedKinds.contains(where: normalized.contains) else {
            return false
        }
        return normalized.range(
            of: #"-\d{4}-\d{2}-\d{2}$"#,
            options: .regularExpression
        ) == nil
    }
}

struct SmartMarkerGeneratedCandidate: Equatable, Sendable {
    let segmentID: Int
    let endSegmentID: Int?
    let label: String
    let explanation: String
    let relevanceScore: Double

    init(
        segmentID: Int,
        endSegmentID: Int? = nil,
        label: String,
        explanation: String,
        relevanceScore: Double
    ) {
        self.segmentID = segmentID
        self.endSegmentID = endSegmentID
        self.label = label
        self.explanation = explanation
        self.relevanceScore = relevanceScore
    }
}

enum SmartMarkerRefinementAction: String, Codable, Sendable {
    case message
    case replace
}

struct SmartMarkerRefinementRequest: Sendable {
    let entries: [SmartMarkerTranscriptEntry]
    let recipe: SmartMarkerAnalysisRecipe
    let currentSuggestions: [SmartMarkerSuggestion]
    let currentDocumentText: String
    let conversation: [SmartMarkerRefinementMessage]
    let instruction: String
    let maximumResults: Int
}

struct SmartMarkerRefinementResponse: Equatable, Sendable {
    let action: SmartMarkerRefinementAction
    let message: String
    let suggestions: [SmartMarkerGeneratedCandidate]
    let documentText: String?
}

enum SmartMarkerProviderError: LocalizedError {
    case unavailable(String)
    case sectionBlocked
    case invalidResponse(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidResponse(let message), .requestFailed(let message):
            return message
        case .sectionBlocked:
            return "This transcript section could not be analyzed."
        }
    }
}

protocol SmartMarkerCandidateProvider: Sendable {
    var id: SmartMarkerProviderID { get }
    var displayName: String { get }
    var transcriptTokenLimit: Int { get }
    var maximumCandidatesPerWindow: Int { get }

    func generateCandidates(
        entries: [SmartMarkerTranscriptEntry],
        recipe: SmartMarkerAnalysisRecipe,
        limit: Int
    ) async throws -> [SmartMarkerGeneratedCandidate]

    func generateDocument(
        entries: [SmartMarkerTranscriptEntry],
        recipe: SmartMarkerAnalysisRecipe
    ) async throws -> String

    func refine(
        request: SmartMarkerRefinementRequest
    ) async throws -> SmartMarkerRefinementResponse
}

enum SmartMarkerProviderFactory {
    static func availabilityMessage(for id: SmartMarkerProviderID) -> String? {
        switch id {
        case .appleIntelligence:
            return AppleSmartMarkerProvider.availabilityMessage()
        case .openAI:
            return SmartMarkerPreferences.hasOpenAIKey
                ? nil
                : "Add an OpenAI API key in Settings > AI."
        case .claude:
            return SmartMarkerPreferences.hasClaudeKey
                ? nil
                : "Add an Anthropic API key in Settings > AI."
        case .gemini:
            return SmartMarkerPreferences.hasGeminiKey
                ? nil
                : "Add a Gemini API key in Settings > AI."
        }
    }

    static func makeProvider(
        id: SmartMarkerProviderID,
        modelIdentifier: String?
    ) throws -> any SmartMarkerCandidateProvider {
        switch id {
        case .appleIntelligence:
            if let message = AppleSmartMarkerProvider.availabilityMessage() {
                throw SmartMarkerProviderError.unavailable(message)
            }
            return AppleSmartMarkerProvider()
        case .openAI:
            guard let key = SecureCredentialStore.value(
                for: SmartMarkerPreferences.openAIKeychainAccount
            ) else {
                throw SmartMarkerProviderError.unavailable(
                    "Add an OpenAI API key in Settings > AI."
                )
            }
            return OpenAISmartMarkerProvider(
                apiKey: key,
                model: modelIdentifier ?? SmartMarkerPreferences.openAIModel
            )
        case .claude:
            guard let key = SecureCredentialStore.value(
                for: SmartMarkerPreferences.claudeKeychainAccount
            ) else {
                throw SmartMarkerProviderError.unavailable(
                    "Add an Anthropic API key in Settings > AI."
                )
            }
            return ClaudeSmartMarkerProvider(
                apiKey: key,
                model: modelIdentifier ?? SmartMarkerPreferences.claudeModel
            )
        case .gemini:
            guard let key = SecureCredentialStore.value(
                for: SmartMarkerPreferences.geminiKeychainAccount
            ) else {
                throw SmartMarkerProviderError.unavailable(
                    "Add a Gemini API key in Settings > AI."
                )
            }
            return GeminiSmartMarkerProvider(
                apiKey: key,
                model: modelIdentifier ?? SmartMarkerPreferences.geminiModel
            )
        }
    }

    static func transcriptTokenLimit(for id: SmartMarkerProviderID) -> Int {
        switch id {
        case .appleIntelligence: return 2_800
        case .openAI: return 120_000
        case .claude: return 180_000
        case .gemini: return 120_000
        }
    }
}

struct AppleSmartMarkerProvider: SmartMarkerCandidateProvider {
    let id = SmartMarkerProviderID.appleIntelligence
    let displayName = "Apple Intelligence"
    let transcriptTokenLimit = 2_800
    let maximumCandidatesPerWindow = 8

    static func availabilityMessage() -> String? {
        guard #available(macOS 26.0, *) else {
            return "Apple Intelligence AI Suggestions requires macOS 26 or later."
        }

        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "Apple Intelligence requires a supported Mac."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still preparing its on-device model. Try again later."
        @unknown default:
            return "Apple Intelligence is not currently available."
        }
    }

    func generateCandidates(
        entries: [SmartMarkerTranscriptEntry],
        recipe: SmartMarkerAnalysisRecipe,
        limit: Int
    ) async throws -> [SmartMarkerGeneratedCandidate] {
        guard #available(macOS 26.0, *) else {
            throw SmartMarkerProviderError.unavailable(
                "Apple Intelligence AI Suggestions requires macOS 26 or later."
            )
        }

        do {
            let transcript = SmartMarkerProviderPrompt.transcript(
                from: entries,
                recipe: recipe
            )
            let model = SystemLanguageModel(
                useCase: .general,
                guardrails: .permissiveContentTransformations
            )
            let session = LanguageModelSession(
                model: model,
                instructions: """
                You are an editorial assistant transforming an existing transcript into timeline annotations.
                Analyze the source without endorsing, extending, or imitating it.
                """
            )
            let validIDs = entries.map { String($0.ordinal) }.joined(separator: ", ")
            let response = try await session.respond(
                to: SmartMarkerProviderPrompt.applePrompt(
                    transcript: transcript,
                    validIDs: validIDs,
                    recipe: recipe,
                    limit: limit
                )
            )
            if ProcessInfo.processInfo.environment["SMART_MARKER_DEBUG"] == "1" {
                FileHandle.standardError.write(
                    Data("Smart marker response:\n\(response.content)\n".utf8)
                )
            }
            return SmartMarkerProviderPrompt.parseAppleResponse(
                response.content,
                recipe: recipe
            )
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation(_), .refusal(_, _):
                throw SmartMarkerProviderError.sectionBlocked
            default:
                throw error
            }
        }
    }

    func generateDocument(
        entries: [SmartMarkerTranscriptEntry],
        recipe: SmartMarkerAnalysisRecipe
    ) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw SmartMarkerProviderError.unavailable(
                "Apple Intelligence AI Suggestions requires macOS 26 or later."
            )
        }

        do {
            let transcript = SmartMarkerProviderPrompt.transcript(
                from: entries,
                recipe: recipe
            )
            let model = SystemLanguageModel(
                useCase: .general,
                guardrails: .permissiveContentTransformations
            )
            let session = LanguageModelSession(
                model: model,
                instructions: """
                You are an editorial assistant transforming an existing transcript into
                useful publication text. Analyze the source without endorsing, extending,
                or imitating it.
                """
            )
            let response = try await session.respond(
                to: SmartMarkerProviderPrompt.documentPrompt(
                    transcript: transcript,
                    recipe: recipe
                )
            )
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation(_), .refusal(_, _):
                throw SmartMarkerProviderError.sectionBlocked
            default:
                throw error
            }
        }
    }

    func refine(
        request: SmartMarkerRefinementRequest
    ) async throws -> SmartMarkerRefinementResponse {
        guard #available(macOS 26.0, *) else {
            throw SmartMarkerProviderError.unavailable(
                "Apple Intelligence AI Suggestions requires macOS 26 or later."
            )
        }
        do {
            let model = SystemLanguageModel(
                useCase: .general,
                guardrails: .permissiveContentTransformations
            )
            let session = LanguageModelSession(
                model: model,
                instructions: """
                You are an editorial assistant discussing and revising results derived from
                an existing transcript. Follow the requested JSON response contract exactly.
                """
            )
            let response = try await session.respond(
                to: SmartMarkerProviderPrompt.refinementPrompt(for: request)
            )
            return try SmartMarkerProviderPrompt.parseRefinementJSON(response.content)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation(_), .refusal(_, _):
                throw SmartMarkerProviderError.sectionBlocked
            default:
                throw error
            }
        }
    }
}

struct OpenAISmartMarkerProvider: SmartMarkerCandidateProvider {
    let id = SmartMarkerProviderID.openAI
    let displayName = "OpenAI"
    let transcriptTokenLimit = 120_000
    let maximumCandidatesPerWindow = 60

    private let client: OpenAIResponsesClient

    init(apiKey: String, model: String) {
        client = OpenAIResponsesClient(apiKey: apiKey, model: model)
    }

    func generateCandidates(
        entries: [SmartMarkerTranscriptEntry],
        recipe: SmartMarkerAnalysisRecipe,
        limit: Int
    ) async throws -> [SmartMarkerGeneratedCandidate] {
        let transcript = SmartMarkerProviderPrompt.transcript(
            from: entries,
            recipe: recipe
        )
        return try await client.generateMarkers(
            transcript: transcript,
            recipe: recipe,
            limit: limit
        )
    }

    func generateDocument(
        entries: [SmartMarkerTranscriptEntry],
        recipe: SmartMarkerAnalysisRecipe
    ) async throws -> String {
        let transcript = SmartMarkerProviderPrompt.transcript(
            from: entries,
            recipe: recipe
        )
        return try await client.generateDocument(
            transcript: transcript,
            recipe: recipe
        )
    }

    func refine(
        request: SmartMarkerRefinementRequest
    ) async throws -> SmartMarkerRefinementResponse {
        try await client.refine(request: request)
    }
}

enum SmartMarkerProviderPrompt {
    static func transcript(
        from entries: [SmartMarkerTranscriptEntry],
        recipe: SmartMarkerAnalysisRecipe
    ) -> String {
        entries.map { entry in
            if recipe.textMode == .timestampedList {
                return "[\(entry.ordinal)] [\(formatSmartMarkerChapterTimestamp(entry.start))] \(entry.text)"
            }
            return "[\(entry.ordinal)] \(entry.text)"
        }.joined(separator: "\n")
    }

    static func task(for recipe: SmartMarkerAnalysisRecipe) -> String {
        if case .custom(let customRecipe) = recipe {
            return customRecipe.instructions
        }
        switch recipe.builtInRecipe {
        case .topicChanges?:
            return "Find genuine changes in subject or conversational direction. Do not mark routine sentence boundaries."
        case .highlights?:
            return "Find strong standalone quotes, important announcements, clear explanations, or especially consequential moments."
        case .adBreaks?:
            return """
            Find places to insert dynamic ad markers. Prefer points after a completed thought,
            answer, or subject where an ad would not interrupt a sentence, argument, or
            emotionally sensitive moment. Favor clear transitions and completed exchanges.
            """
        case .notableExcerpts?:
            return """
            Find self-contained passages that would work as clips or quoted excerpts.
            Each passage must begin at a natural entry point, end after the complete thought,
            and remain understandable without unnecessary surrounding conversation.
            """
        case .youtubeChapters?:
            return """
            Create a concise chapter list that covers the transcript in chronological order.
            Each chapter must begin where a meaningful subject or section starts. Do not
            create overly granular chapters, and use fewer than the allowed maximum when that
            gives the viewer a better experience. Include an opening chapter near the
            beginning and cover the entire transcript through its final meaningful section;
            do not spend every chapter on the beginning. When the final third contains a
            distinct subject or section, include a chapter from that final third. Uneven
            spacing is fine. If an ad break clearly identifies its sponsor, make that a
            chapter and include the sponsor in its short title. Avoid guessing the spelling
            of names or proper nouns; use accurate generic wording when uncertain. Write
            short, single-line titles suitable for a YouTube description.
            """
        case nil:
            return ""
        }
    }

    static func applePrompt(
        transcript: String,
        validIDs: String,
        recipe: SmartMarkerAnalysisRecipe,
        limit: Int
    ) -> String {
        if recipe.outputKind == .text {
            let itemName = recipe.isYouTubeChapters ? "chapter" : "text item"
            let itemNamePlural = recipe.isYouTubeChapters ? "chapters" : "text items"
            return """
            Analyze the transcript excerpt below. \(task(for: recipe))
            Select no more than \(limit) \(itemNamePlural).

            The only valid segment IDs are: \(validIDs)

            Your entire response must contain either NONE or one record per \(itemName).
            Each record must have four fields separated by vertical bars:
            MARKER | numeric segment ID | short title | brief internal reason

            Do not repeat that format as a heading or template. Replace every field with a
            concrete value from the transcript. Use only a valid segment ID listed above.
            Return records in chronological order. Keep titles to six words or fewer.

            Transcript:
            \(transcript)
            """
        }
        if recipe.producesRanges {
            return """
            Analyze the transcript excerpt below. \(task(for: recipe))
            Select no more than \(limit) of the strongest ranges.

            The only valid segment IDs are: \(validIDs)

            Your entire response must contain either NONE or one record per selected range.
            Each record must have five fields separated by vertical bars:
            RANGE | numeric start segment ID | numeric end segment ID | short label | brief editorial reason

            Use only valid segment IDs listed above. The end ID must occur after the start ID.
            Return the strongest suggestions first. Keep labels to six words or fewer.

            Transcript:
            \(transcript)
            """
        }
        return """
        Analyze the transcript excerpt below. \(task(for: recipe))
        Select no more than \(limit) of the strongest timeline points.

        The only valid segment IDs are: \(validIDs)

        Your entire response must contain either NONE or one record per selected point.
        Each record must have four fields separated by vertical bars:
        MARKER | numeric segment ID | short label | brief editorial reason

        Do not repeat that format as a heading or template. Replace every field with a
        concrete value from the transcript. Use only a valid segment ID listed above.
        Return the strongest suggestions first. Keep labels to six words or fewer.

        Transcript:
        \(transcript)
        """
    }

    static func cloudPrompt(
        transcript: String,
        recipe: SmartMarkerAnalysisRecipe,
        limit: Int
    ) -> String {
        let rangeInstruction = recipe.producesRanges
            ? """
            For each option, return segment_id for its beginning and end_segment_id for its
            inclusive ending anchor. The ending must occur after the beginning.
            """
            : "For each option, return segment_id and set end_segment_id to null."
        let rankingInstruction = recipe.outputKind == .text
            ? """
            Return records in chronological order with concise display text in label.
            The explanation is internal app metadata and must briefly identify why the
            record matches the requested analysis.
            """
            : """
            Rank quality rather than trying to distribute markers evenly. Give each option a
            relevance score from 0 to 100.
            """
        return """
        \(task(for: recipe))

        Review the transcript as a whole and return no more than \(limit) genuinely useful
        editorial options. Use only numeric segment IDs that appear in square brackets.
        \(rangeInstruction)
        \(rankingInstruction)
        Give each option a relevance score from 0 to 100. Keep labels to six words or fewer.

        Transcript:
        \(transcript)
        """
    }

    static func documentPrompt(
        transcript: String,
        recipe: SmartMarkerAnalysisRecipe
    ) -> String {
        """
        \(task(for: recipe))

        Create the requested final text from the transcript below. Return only the finished
        text a user could copy and use directly. Do not include analysis, preambles, labels,
        timecodes, JSON, or commentary about your process unless the custom instructions
        explicitly request them.

        Transcript:
        \(transcript)
        """
    }

    static func refinementPrompt(
        for request: SmartMarkerRefinementRequest
    ) -> String {
        let entriesBySegmentID = Dictionary(
            grouping: request.entries,
            by: \.segmentID
        )
        let currentResults: String
        if request.recipe.isDocumentText {
            currentResults = request.currentDocumentText
        } else {
            currentResults = request.currentSuggestions.map { suggestion in
                let startEntry = entriesBySegmentID[suggestion.sourceSegmentID]?.min(by: {
                    abs($0.start - suggestion.seconds) < abs($1.start - suggestion.seconds)
                }) ?? request.entries.min(by: {
                        abs($0.start - suggestion.seconds) < abs($1.start - suggestion.seconds)
                    })
                let endEntry = suggestion.endSeconds.flatMap { endSeconds in
                    request.entries.min(by: {
                        abs($0.end - endSeconds) < abs($1.end - endSeconds)
                    })
                }
                let endText = endEntry.map { " end_segment_id=\($0.ordinal)" } ?? ""
                return """
                segment_id=\(startEntry?.ordinal ?? 0)\(endText) | \(suggestion.label) | \(suggestion.explanation)
                """
            }.joined(separator: "\n")
        }
        let conversation = request.conversation.suffix(12).map {
            "\($0.role == .user ? "USER" : "ASSISTANT"): \($0.text)"
        }.joined(separator: "\n")
        let transcript = transcript(from: request.entries, recipe: request.recipe)
        let replacementRules: String
        if request.recipe.isDocumentText {
            replacementRules = """
            For a replacement, put the complete revised document in document_text and return
            an empty suggestions array.
            """
        } else {
            replacementRules = """
            For a replacement, return the complete revised result set in suggestions, not a
            diff. Use only segment IDs from the transcript. Set document_text to null.
            Marker and timestamped-text results require end_segment_id to be null. Range
            results require a later valid end_segment_id.
            """
        }
        return """
        The user is discussing or refining the current results of this analysis:
        \(task(for: request.recipe))

        Respond naturally to the user's request. If the user is asking a question or discussing
        the results without requesting a change, use action "message" and leave the results
        unchanged. If the user requests a change, use action "replace" and provide the complete
        revised results. Do not force a revision when a conversational answer is more appropriate.

        \(replacementRules)
        Return no more than \(request.maximumResults) suggestions. Include a concise conversational
        message explaining what you did or answering the question.

        CURRENT RESULTS:
        \(currentResults)

        PRIOR CONVERSATION:
        \(conversation.isEmpty ? "(none)" : conversation)

        NEW USER MESSAGE:
        \(request.instruction)

        TRANSCRIPT:
        \(transcript)

        Return only JSON with these fields:
        action: "message" or "replace"
        message: string
        document_text: string or null
        suggestions: array of objects containing segment_id, end_segment_id, label,
        explanation, and relevance_score
        """
    }

    static func parseRefinementJSON(_ response: String) throws -> SmartMarkerRefinementResponse {
        var normalized = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("```") {
            normalized = normalized
                .replacingOccurrences(
                    of: #"^```(?:json)?\s*"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"\s*```$"#,
                    with: "",
                    options: .regularExpression
                )
        }
        if let firstBrace = normalized.firstIndex(of: "{"),
           let lastBrace = normalized.lastIndex(of: "}") {
            normalized = String(normalized[firstBrace...lastBrace])
        }
        guard let data = normalized.data(using: .utf8) else {
            throw SmartMarkerProviderError.invalidResponse(
                "The AI returned refinement data In/Out could not read."
            )
        }
        do {
            let payload = try JSONDecoder().decode(
                SmartMarkerRefinementPayload.self,
                from: data
            )
            return payload.response
        } catch {
            throw SmartMarkerProviderError.invalidResponse(
                "The AI returned refinement data In/Out could not read."
            )
        }
    }

    static func parseAppleResponse(
        _ response: String,
        recipe: SmartMarkerAnalysisRecipe = .topicChanges
    ) -> [SmartMarkerGeneratedCandidate] {
        response
            .components(separatedBy: .newlines)
            .compactMap { line -> SmartMarkerGeneratedCandidate? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      trimmed.uppercased() != "NONE",
                      !trimmed.hasPrefix("```") else {
                    return nil
                }
                let separator: Character = trimmed.contains("\t") ? "\t" : "|"
                let fields = trimmed.split(
                    separator: separator,
                    maxSplits: recipe.producesRanges ? 4 : 3,
                    omittingEmptySubsequences: false
                ).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard fields.count == (recipe.producesRanges ? 5 : 4) else { return nil }

                let prefix = recipe.producesRanges ? "RANGE" : "MARKER"
                let hasExpectedPrefix = fields[0].uppercased() == prefix
                let hasNumericRowPrefix = !recipe.producesRanges && Int(fields[0]) != nil
                guard hasExpectedPrefix || hasNumericRowPrefix,
                      let startIDRange = fields[1].range(
                        of: #"\d+"#,
                        options: .regularExpression
                      ),
                      let segmentID = Int(fields[1][startIDRange]) else {
                    return nil
                }

                let endSegmentID: Int?
                let labelIndex: Int
                if recipe.producesRanges {
                    guard let endIDRange = fields[2].range(
                        of: #"\d+"#,
                        options: .regularExpression
                    ), let parsedEndID = Int(fields[2][endIDRange]),
                       parsedEndID > segmentID else {
                        return nil
                    }
                    endSegmentID = parsedEndID
                    labelIndex = 3
                } else {
                    endSegmentID = nil
                    labelIndex = 2
                }
                guard !fields[labelIndex].isEmpty else { return nil }
                return SmartMarkerGeneratedCandidate(
                    segmentID: segmentID,
                    endSegmentID: endSegmentID,
                    label: fields[labelIndex],
                    explanation: fields[labelIndex + 1],
                    relevanceScore: 100
                )
            }
            .enumerated()
            .map { index, candidate in
                SmartMarkerGeneratedCandidate(
                    segmentID: candidate.segmentID,
                    endSegmentID: candidate.endSegmentID,
                    label: candidate.label,
                    explanation: candidate.explanation,
                    relevanceScore: max(0, 100 - (Double(index) * 2))
                )
            }
    }
}

private struct SmartMarkerRefinementPayload: Decodable {
    let action: SmartMarkerRefinementAction
    let message: String
    let documentText: String?
    let suggestions: [Suggestion]

    var response: SmartMarkerRefinementResponse {
        SmartMarkerRefinementResponse(
            action: action,
            message: message,
            suggestions: suggestions.map {
                SmartMarkerGeneratedCandidate(
                    segmentID: $0.segmentID,
                    endSegmentID: $0.endSegmentID,
                    label: $0.label,
                    explanation: $0.explanation,
                    relevanceScore: $0.relevanceScore
                )
            },
            documentText: documentText
        )
    }

    struct Suggestion: Decodable {
        let segmentID: Int
        let endSegmentID: Int?
        let label: String
        let explanation: String
        let relevanceScore: Double

        enum CodingKeys: String, CodingKey {
            case segmentID = "segment_id"
            case endSegmentID = "end_segment_id"
            case label
            case explanation
            case relevanceScore = "relevance_score"
        }
    }

    enum CodingKeys: String, CodingKey {
        case action
        case message
        case documentText = "document_text"
        case suggestions
    }
}

struct OpenAIResponsesClient: Sendable {
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SmartMarkerPreferences.defaultOpenAIModel
            : model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func generateMarkers(
        transcript: String,
        recipe: SmartMarkerAnalysisRecipe,
        limit: Int
    ) async throws -> [SmartMarkerGeneratedCandidate] {
        let data = try Self.markerRequestBody(
            model: model,
            transcript: transcript,
            recipe: recipe,
            limit: limit
        )
        let responseData = try await performRequest(
            path: "/v1/responses",
            method: "POST",
            body: data
        )
        return try Self.parseMarkerResponse(responseData)
    }

    func generateDocument(
        transcript: String,
        recipe: SmartMarkerAnalysisRecipe
    ) async throws -> String {
        let data = try Self.documentRequestBody(
            model: model,
            transcript: transcript,
            recipe: recipe
        )
        let responseData = try await performRequest(
            path: "/v1/responses",
            method: "POST",
            body: data
        )
        return try Self.parseDocumentResponse(responseData)
    }

    func refine(
        request: SmartMarkerRefinementRequest
    ) async throws -> SmartMarkerRefinementResponse {
        let data = try Self.refinementRequestBody(
            model: model,
            request: request
        )
        let responseData = try await performRequest(
            path: "/v1/responses",
            method: "POST",
            body: data
        )
        return try Self.parseRefinementResponse(responseData)
    }

    static func markerRequestBody(
        model: String,
        transcript: String,
        recipe: SmartMarkerAnalysisRecipe,
        limit: Int
    ) throws -> Data {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "markers": [
                    "type": "array",
                    "maxItems": limit,
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "segment_id": ["type": "integer"],
                            "end_segment_id": [
                                "type": ["integer", "null"]
                            ],
                            "label": ["type": "string"],
                            "explanation": ["type": "string"],
                            "relevance_score": [
                                "type": "number",
                                "minimum": 0,
                                "maximum": 100
                            ]
                        ],
                        "required": [
                            "segment_id",
                            "end_segment_id",
                            "label",
                            "explanation",
                            "relevance_score"
                        ]
                    ]
                ]
            ],
            "required": ["markers"]
        ]
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "instructions": """
                You are an experienced editor placing useful timeline markers in news,
                interviews, and political commentary. Analyze the supplied transcript;
                do not rewrite it.
                """,
            "input": SmartMarkerProviderPrompt.cloudPrompt(
                transcript: transcript,
                recipe: recipe,
                limit: limit
            ),
            "max_output_tokens": 8_000,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "smart_marker_suggestions",
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func documentRequestBody(
        model: String,
        transcript: String,
        recipe: SmartMarkerAnalysisRecipe
    ) throws -> Data {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "text": ["type": "string"]
            ],
            "required": ["text"]
        ]
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "instructions": """
                You are an experienced editorial assistant creating publication-ready text
                from transcripts of news, interviews, and political commentary.
                """,
            "input": SmartMarkerProviderPrompt.documentPrompt(
                transcript: transcript,
                recipe: recipe
            ),
            "max_output_tokens": 8_000,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "analysis_document",
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func refinementRequestBody(
        model: String,
        request: SmartMarkerRefinementRequest
    ) throws -> Data {
        let suggestionSchema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "segment_id": ["type": "integer"],
                "end_segment_id": ["type": ["integer", "null"]],
                "label": ["type": "string"],
                "explanation": ["type": "string"],
                "relevance_score": [
                    "type": "number",
                    "minimum": 0,
                    "maximum": 100
                ]
            ],
            "required": [
                "segment_id",
                "end_segment_id",
                "label",
                "explanation",
                "relevance_score"
            ]
        ]
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["message", "replace"]
                ],
                "message": ["type": "string"],
                "document_text": ["type": ["string", "null"]],
                "suggestions": [
                    "type": "array",
                    "maxItems": request.maximumResults,
                    "items": suggestionSchema
                ]
            ],
            "required": [
                "action",
                "message",
                "document_text",
                "suggestions"
            ]
        ]
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "instructions": """
                You are an experienced editorial assistant discussing and revising analysis
                results derived from a supplied transcript.
                """,
            "input": SmartMarkerProviderPrompt.refinementPrompt(for: request),
            "max_output_tokens": 8_000,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "analysis_refinement",
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    func testConnection() async throws {
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "input": "Reply with OK.",
            "max_output_tokens": 16
        ]
        _ = try await performRequest(
            path: "/v1/responses",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    func listModels() async throws -> [String] {
        let data = try await performRequest(
            path: "/v1/models",
            method: "GET",
            body: nil
        )
        return try Self.parseModelList(data)
    }

    static func parseModelList(_ data: Data) throws -> [String] {
        do {
            let payload = try JSONDecoder().decode(ModelListPayload.self, from: data)
            return payload.data.map(\.id)
        } catch {
            throw SmartMarkerProviderError.invalidResponse(
                "OpenAI returned a model list In/Out could not read."
            )
        }
    }

    static func parseMarkerResponse(_ data: Data) throws -> [SmartMarkerGeneratedCandidate] {
        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        } catch {
            throw SmartMarkerProviderError.invalidResponse(
                "OpenAI returned a response In/Out could not read."
            )
        }
        guard let outputText = envelope.output
            .compactMap(\.content)
            .flatMap({ $0 })
            .first(where: { $0.type == "output_text" })?
            .text,
              let jsonData = outputText.data(using: String.Encoding.utf8) else {
            throw SmartMarkerProviderError.invalidResponse(
                "OpenAI did not return marker suggestions."
            )
        }
        do {
            let payload = try JSONDecoder().decode(MarkerPayload.self, from: jsonData)
            return payload.markers.map {
                SmartMarkerGeneratedCandidate(
                    segmentID: $0.segmentID,
                    endSegmentID: $0.endSegmentID,
                    label: $0.label,
                    explanation: $0.explanation,
                    relevanceScore: $0.relevanceScore
                )
            }
        } catch {
            throw SmartMarkerProviderError.invalidResponse(
                "OpenAI returned marker data In/Out could not read."
            )
        }
    }

    static func parseDocumentResponse(_ data: Data) throws -> String {
        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        } catch {
            throw SmartMarkerProviderError.invalidResponse(
                "OpenAI returned a response In/Out could not read."
            )
        }
        guard let outputText = envelope.output
            .compactMap(\.content)
            .flatMap({ $0 })
            .first(where: { $0.type == "output_text" })?
            .text,
              let jsonData = outputText.data(using: String.Encoding.utf8) else {
            throw SmartMarkerProviderError.invalidResponse(
                "OpenAI did not return the requested text."
            )
        }
        do {
            let payload = try JSONDecoder().decode(DocumentPayload.self, from: jsonData)
            let text = payload.text.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            )
            guard !text.isEmpty else {
                throw SmartMarkerProviderError.invalidResponse(
                    "OpenAI returned empty text."
                )
            }
            return text
        } catch let error as SmartMarkerProviderError {
            throw error
        } catch {
            throw SmartMarkerProviderError.invalidResponse(
                "OpenAI returned text data In/Out could not read."
            )
        }
    }

    static func parseRefinementResponse(
        _ data: Data
    ) throws -> SmartMarkerRefinementResponse {
        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        } catch {
            throw SmartMarkerProviderError.invalidResponse(
                "OpenAI returned a response In/Out could not read."
            )
        }
        guard let outputText = envelope.output
            .compactMap(\.content)
            .flatMap({ $0 })
            .first(where: { $0.type == "output_text" })?
            .text else {
            throw SmartMarkerProviderError.invalidResponse(
                "OpenAI did not return a refinement response."
            )
        }
        return try SmartMarkerProviderPrompt.parseRefinementJSON(outputText)
    }

    private func performRequest(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Data {
        guard let url = URL(string: "https://api.openai.com\(path)") else {
            throw SmartMarkerProviderError.requestFailed("The OpenAI endpoint is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 180
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SmartMarkerProviderError.requestFailed(
                "Could not reach OpenAI: \(error.localizedDescription)"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw SmartMarkerProviderError.requestFailed(
                "OpenAI returned an invalid network response."
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let apiError = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            let detail = apiError?.error.message ?? HTTPURLResponse.localizedString(
                forStatusCode: http.statusCode
            )
            let prefix: String
            switch http.statusCode {
            case 401: prefix = "OpenAI rejected the API key."
            case 429: prefix = "OpenAI rate limit or account quota reached."
            default: prefix = "OpenAI request failed (\(http.statusCode))."
            }
            throw SmartMarkerProviderError.requestFailed("\(prefix) \(detail)")
        }
        return data
    }

    private struct ResponseEnvelope: Decodable {
        let output: [OutputItem]
    }

    private struct OutputItem: Decodable {
        let content: [ContentItem]?
    }

    private struct ContentItem: Decodable {
        let type: String
        let text: String?
    }

    private struct MarkerPayload: Decodable {
        let markers: [Marker]
    }

    private struct DocumentPayload: Decodable {
        let text: String
    }

    private struct ModelListPayload: Decodable {
        let data: [Model]

        struct Model: Decodable {
            let id: String
        }
    }

    private struct Marker: Decodable {
        let segmentID: Int
        let endSegmentID: Int?
        let label: String
        let explanation: String
        let relevanceScore: Double

        enum CodingKeys: String, CodingKey {
            case segmentID = "segment_id"
            case endSegmentID = "end_segment_id"
            case label
            case explanation
            case relevanceScore = "relevance_score"
        }
    }

    private struct ErrorEnvelope: Decodable {
        let error: APIError
    }

    private struct APIError: Decodable {
        let message: String
    }
}
