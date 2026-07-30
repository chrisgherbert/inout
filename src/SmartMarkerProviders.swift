import Foundation
import FoundationModels

enum SmartMarkerProviderID: String, CaseIterable, Identifiable, Sendable {
    case appleIntelligence
    case openAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .openAI: return "OpenAI"
        }
    }

    var detail: String {
        switch self {
        case .appleIntelligence:
            return "Runs privately on this Mac."
        case .openAI:
            return "Sends transcript text to OpenAI using your API key."
        }
    }
}

enum SmartMarkerPreferences {
    static let providerKey = "prefs.smartMarkerProvider"
    static let openAIModelKey = "prefs.smartMarkerOpenAIModel"
    static let openAIKeychainAccount = "openai-api-key"
    static let defaultOpenAIModel = "chat-latest"

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
        recipe: SmartMarkerRecipe,
        limit: Int
    ) async throws -> [SmartMarkerGeneratedCandidate]
}

enum SmartMarkerProviderFactory {
    static func availabilityMessage(for id: SmartMarkerProviderID) -> String? {
        switch id {
        case .appleIntelligence:
            return AppleSmartMarkerProvider.availabilityMessage()
        case .openAI:
            return SmartMarkerPreferences.hasOpenAIKey
                ? nil
                : "Add an OpenAI API key in Settings > Analyze."
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
                    "Add an OpenAI API key in Settings > Analyze."
                )
            }
            return OpenAISmartMarkerProvider(
                apiKey: key,
                model: modelIdentifier ?? SmartMarkerPreferences.openAIModel
            )
        }
    }

    static func transcriptTokenLimit(for id: SmartMarkerProviderID) -> Int {
        switch id {
        case .appleIntelligence: return 2_800
        case .openAI: return 120_000
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
        recipe: SmartMarkerRecipe,
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
        recipe: SmartMarkerRecipe,
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
}

enum SmartMarkerProviderPrompt {
    static func transcript(
        from entries: [SmartMarkerTranscriptEntry],
        recipe: SmartMarkerRecipe
    ) -> String {
        entries.map { entry in
            if recipe == .youtubeChapters {
                return "[\(entry.ordinal)] [\(formatSmartMarkerChapterTimestamp(entry.start))] \(entry.text)"
            }
            return "[\(entry.ordinal)] \(entry.text)"
        }.joined(separator: "\n")
    }

    static func task(for recipe: SmartMarkerRecipe) -> String {
        switch recipe {
        case .topicChanges:
            return "Find genuine changes in subject or conversational direction. Do not mark routine sentence boundaries."
        case .highlights:
            return "Find strong standalone quotes, important announcements, clear explanations, or especially consequential moments."
        case .adBreaks:
            return """
            Find places to insert dynamic ad markers. Prefer points after a completed thought,
            answer, or subject where an ad would not interrupt a sentence, argument, or
            emotionally sensitive moment. Favor clear transitions and completed exchanges.
            """
        case .notableExcerpts:
            return """
            Find self-contained passages that would work as clips or quoted excerpts.
            Each passage must begin at a natural entry point, end after the complete thought,
            and remain understandable without unnecessary surrounding conversation.
            """
        case .youtubeChapters:
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
        }
    }

    static func applePrompt(
        transcript: String,
        validIDs: String,
        recipe: SmartMarkerRecipe,
        limit: Int
    ) -> String {
        if recipe.outputKind == .text {
            return """
            Analyze the transcript excerpt below. \(task(for: recipe))
            Select no more than \(limit) chapters.

            The only valid segment IDs are: \(validIDs)

            Your entire response must contain either NONE or one record per chapter.
            Each record must have four fields separated by vertical bars:
            MARKER | numeric segment ID | short chapter title | brief internal reason

            Do not repeat that format as a heading or template. Replace every field with a
            concrete value from the transcript. Use only a valid segment ID listed above.
            Return chapters in chronological order. Keep titles to six words or fewer.

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

    static func openAIPrompt(
        transcript: String,
        recipe: SmartMarkerRecipe,
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
            Return chapters in chronological order with a concise chapter title in label.
            The explanation is internal app metadata and must briefly identify the section.
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

    static func parseAppleResponse(
        _ response: String,
        recipe: SmartMarkerRecipe = .topicChanges
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
        recipe: SmartMarkerRecipe,
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

    static func markerRequestBody(
        model: String,
        transcript: String,
        recipe: SmartMarkerRecipe,
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
            "input": SmartMarkerProviderPrompt.openAIPrompt(
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
