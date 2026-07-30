import Foundation

enum SmartMarkerClaudeModelCatalog {
    private static let recommended: [(id: String, title: String, detail: String)] = [
        ("claude-sonnet-5", "Claude Sonnet 5", "Recommended balance of quality, speed, and cost."),
        ("claude-opus-5", "Claude Opus 5", "Highest quality for complex editorial analysis."),
        ("claude-sonnet-4-6", "Claude Sonnet 4.6", "Recommended balance of quality, speed, and cost."),
        ("claude-opus-4-8", "Claude Opus 4.8", "High-quality established Claude option."),
        ("claude-haiku-4-5", "Claude Haiku 4.5", "Fastest and lowest-cost Claude option.")
    ]

    static func options(from modelIDs: [String]) -> [SmartMarkerModelOption] {
        catalogOptions(
            modelIDs: modelIDs.filter { $0.lowercased().hasPrefix("claude-") },
            recommended: recommended
        )
    }
}

enum SmartMarkerGeminiModelCatalog {
    private static let recommended: [(id: String, title: String, detail: String)] = [
        ("gemini-3.6-flash", "Gemini 3.6 Flash", "Recommended for fast transcript analysis."),
        ("gemini-3-pro", "Gemini 3 Pro", "Higher quality for complex editorial analysis."),
        ("gemini-2.5-flash", "Gemini 2.5 Flash", "Fast, established Gemini option."),
        ("gemini-2.5-pro", "Gemini 2.5 Pro", "Established high-quality Gemini option.")
    ]

    static func options(from modelIDs: [String]) -> [SmartMarkerModelOption] {
        let compatible = modelIDs.filter {
            let id = $0.lowercased()
            return id.hasPrefix("gemini-") &&
                !["audio", "embedding", "image", "live", "tts"].contains(where: id.contains)
        }
        return catalogOptions(modelIDs: compatible, recommended: recommended)
    }
}

private func catalogOptions(
    modelIDs: [String],
    recommended: [(id: String, title: String, detail: String)]
) -> [SmartMarkerModelOption] {
    let available = Set(modelIDs)
    let recommendedIDs = Set(recommended.map(\.id))
    let preferred = recommended.compactMap { model -> SmartMarkerModelOption? in
        guard available.contains(model.id) else { return nil }
        return SmartMarkerModelOption(
            id: model.id,
            title: model.title,
            detail: model.detail,
            isRecommended: true
        )
    }
    let remaining = available
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
    return preferred + remaining
}

struct ClaudeSmartMarkerProvider: SmartMarkerCandidateProvider {
    let id = SmartMarkerProviderID.claude
    let displayName = "Claude"
    let transcriptTokenLimit = 180_000
    let maximumCandidatesPerWindow = 60

    private let client: ClaudeMessagesClient

    init(apiKey: String, model: String) {
        client = ClaudeMessagesClient(apiKey: apiKey, model: model)
    }

    func generateCandidates(
        entries: [SmartMarkerTranscriptEntry],
        recipe: SmartMarkerAnalysisRecipe,
        limit: Int
    ) async throws -> [SmartMarkerGeneratedCandidate] {
        try await client.generateMarkers(
            transcript: SmartMarkerProviderPrompt.transcript(from: entries, recipe: recipe),
            recipe: recipe,
            limit: limit
        )
    }

    func generateDocument(
        entries: [SmartMarkerTranscriptEntry],
        recipe: SmartMarkerAnalysisRecipe
    ) async throws -> String {
        try await client.generateDocument(
            transcript: SmartMarkerProviderPrompt.transcript(from: entries, recipe: recipe),
            recipe: recipe
        )
    }

    func refine(request: SmartMarkerRefinementRequest) async throws -> SmartMarkerRefinementResponse {
        try await client.refine(request: request)
    }
}

struct GeminiSmartMarkerProvider: SmartMarkerCandidateProvider {
    let id = SmartMarkerProviderID.gemini
    let displayName = "Gemini"
    let transcriptTokenLimit = 120_000
    let maximumCandidatesPerWindow = 60

    private let client: GeminiGenerateContentClient

    init(apiKey: String, model: String) {
        client = GeminiGenerateContentClient(apiKey: apiKey, model: model)
    }

    func generateCandidates(
        entries: [SmartMarkerTranscriptEntry],
        recipe: SmartMarkerAnalysisRecipe,
        limit: Int
    ) async throws -> [SmartMarkerGeneratedCandidate] {
        try await client.generateMarkers(
            transcript: SmartMarkerProviderPrompt.transcript(from: entries, recipe: recipe),
            recipe: recipe,
            limit: limit
        )
    }

    func generateDocument(
        entries: [SmartMarkerTranscriptEntry],
        recipe: SmartMarkerAnalysisRecipe
    ) async throws -> String {
        try await client.generateDocument(
            transcript: SmartMarkerProviderPrompt.transcript(from: entries, recipe: recipe),
            recipe: recipe
        )
    }

    func refine(request: SmartMarkerRefinementRequest) async throws -> SmartMarkerRefinementResponse {
        try await client.refine(request: request)
    }
}

enum SmartMarkerStructuredOutput {
    static func markerSchema(limit: Int) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "markers": [
                    "type": "array",
                    "maxItems": limit,
                    "items": suggestionSchema
                ]
            ],
            "required": ["markers"]
        ]
    }

    static let documentSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": ["text": ["type": "string"]],
        "required": ["text"]
    ]

    static func refinementSchema(maximumResults: Int) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "action": ["type": "string", "enum": ["message", "replace"]],
                "message": ["type": "string"],
                "document_text": ["type": ["string", "null"]],
                "suggestions": [
                    "type": "array",
                    "maxItems": maximumResults,
                    "items": suggestionSchema
                ]
            ],
            "required": ["action", "message", "document_text", "suggestions"]
        ]
    }

    static func parseMarkers(_ text: String, provider: String) throws
        -> [SmartMarkerGeneratedCandidate] {
        guard let data = text.data(using: .utf8) else {
            throw invalid(provider, result: "marker suggestions")
        }
        do {
            let payload = try JSONDecoder().decode(MarkerPayload.self, from: data)
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
            throw invalid(provider, result: "marker data")
        }
    }

    static func parseDocument(_ text: String, provider: String) throws -> String {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(DocumentPayload.self, from: data) else {
            throw invalid(provider, result: "text data")
        }
        let result = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw SmartMarkerProviderError.invalidResponse("\(provider) returned empty text.")
        }
        return result
    }

    private static let suggestionSchema: [String: Any] = [
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

    private static func invalid(_ provider: String, result: String) -> SmartMarkerProviderError {
        .invalidResponse("\(provider) returned \(result) In/Out could not read.")
    }

    private struct MarkerPayload: Decodable {
        let markers: [Marker]
    }

    private struct DocumentPayload: Decodable {
        let text: String
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
}

struct ClaudeMessagesClient: Sendable {
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? SmartMarkerPreferences.defaultClaudeModel : trimmed
        self.session = session
    }

    func generateMarkers(
        transcript: String,
        recipe: SmartMarkerAnalysisRecipe,
        limit: Int
    ) async throws -> [SmartMarkerGeneratedCandidate] {
        let body = try Self.requestBody(
            model: model,
            system: Self.markerSystemPrompt,
            prompt: SmartMarkerProviderPrompt.cloudPrompt(
                transcript: transcript,
                recipe: recipe,
                limit: limit
            ),
            schema: SmartMarkerStructuredOutput.markerSchema(limit: limit)
        )
        return try SmartMarkerStructuredOutput.parseMarkers(
            Self.outputText(from: try await perform(path: "/v1/messages", method: "POST", body: body)),
            provider: "Claude"
        )
    }

    func generateDocument(
        transcript: String,
        recipe: SmartMarkerAnalysisRecipe
    ) async throws -> String {
        let body = try Self.requestBody(
            model: model,
            system: Self.documentSystemPrompt,
            prompt: SmartMarkerProviderPrompt.documentPrompt(
                transcript: transcript,
                recipe: recipe
            ),
            schema: SmartMarkerStructuredOutput.documentSchema
        )
        return try SmartMarkerStructuredOutput.parseDocument(
            Self.outputText(from: try await perform(path: "/v1/messages", method: "POST", body: body)),
            provider: "Claude"
        )
    }

    func refine(request: SmartMarkerRefinementRequest) async throws
        -> SmartMarkerRefinementResponse {
        let body = try Self.requestBody(
            model: model,
            system: Self.refinementSystemPrompt,
            prompt: SmartMarkerProviderPrompt.refinementPrompt(for: request),
            schema: SmartMarkerStructuredOutput.refinementSchema(
                maximumResults: request.maximumResults
            )
        )
        return try SmartMarkerProviderPrompt.parseRefinementJSON(
            Self.outputText(from: try await perform(path: "/v1/messages", method: "POST", body: body))
        )
    }

    func listModels() async throws -> [String] {
        try Self.parseModelList(
            try await perform(path: "/v1/models?limit=1000", method: "GET", body: nil)
        )
    }

    func testConnection() async throws {
        _ = try await listModels()
    }

    static func requestBody(
        model: String,
        system: String,
        prompt: String,
        schema: [String: Any]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 8_000,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": schema
                ]
            ]
        ])
    }

    static func parseModelList(_ data: Data) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [[String: Any]] else {
            throw SmartMarkerProviderError.invalidResponse(
                "Anthropic returned a model list In/Out could not read."
            )
        }
        return models.compactMap { $0["id"] as? String }
    }

    static func outputText(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"]
                as? String else {
            throw SmartMarkerProviderError.invalidResponse(
                "Claude returned a response In/Out could not read."
            )
        }
        if root["stop_reason"] as? String == "refusal" {
            throw SmartMarkerProviderError.sectionBlocked
        }
        if root["stop_reason"] as? String == "max_tokens" {
            throw SmartMarkerProviderError.invalidResponse(
                "Claude's response exceeded the output limit."
            )
        }
        return text
    }

    private func perform(path: String, method: String, body: Data?) async throws -> Data {
        guard let url = URL(string: "https://api.anthropic.com\(path)") else {
            throw SmartMarkerProviderError.requestFailed("The Anthropic endpoint is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await cloudResponse(
            request: request,
            session: session,
            provider: "Claude"
        )
    }

    static let markerSystemPrompt =
        "You are an experienced editor placing useful timeline markers in news, interviews, and political commentary."
    static let documentSystemPrompt =
        "You are an experienced editorial assistant creating publication-ready text from transcripts."
    static let refinementSystemPrompt =
        "You are an experienced editorial assistant discussing and revising transcript analysis results."
}

struct GeminiGenerateContentClient: Sendable {
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? SmartMarkerPreferences.defaultGeminiModel : trimmed
        self.session = session
    }

    func generateMarkers(
        transcript: String,
        recipe: SmartMarkerAnalysisRecipe,
        limit: Int
    ) async throws -> [SmartMarkerGeneratedCandidate] {
        let text = try await generate(
            system: ClaudeMessagesClient.markerSystemPrompt,
            prompt: SmartMarkerProviderPrompt.cloudPrompt(
                transcript: transcript,
                recipe: recipe,
                limit: limit
            ),
            schema: SmartMarkerStructuredOutput.markerSchema(limit: limit)
        )
        return try SmartMarkerStructuredOutput.parseMarkers(text, provider: "Gemini")
    }

    func generateDocument(
        transcript: String,
        recipe: SmartMarkerAnalysisRecipe
    ) async throws -> String {
        let text = try await generate(
            system: ClaudeMessagesClient.documentSystemPrompt,
            prompt: SmartMarkerProviderPrompt.documentPrompt(
                transcript: transcript,
                recipe: recipe
            ),
            schema: SmartMarkerStructuredOutput.documentSchema
        )
        return try SmartMarkerStructuredOutput.parseDocument(text, provider: "Gemini")
    }

    func refine(request: SmartMarkerRefinementRequest) async throws
        -> SmartMarkerRefinementResponse {
        let text = try await generate(
            system: ClaudeMessagesClient.refinementSystemPrompt,
            prompt: SmartMarkerProviderPrompt.refinementPrompt(for: request),
            schema: SmartMarkerStructuredOutput.refinementSchema(
                maximumResults: request.maximumResults
            )
        )
        return try SmartMarkerProviderPrompt.parseRefinementJSON(text)
    }

    func listModels() async throws -> [String] {
        let data = try await perform(path: "/v1beta/models?pageSize=1000", method: "GET", body: nil)
        return try Self.parseModelList(data)
    }

    func testConnection() async throws {
        _ = try await listModels()
    }

    static func requestBody(system: String, prompt: String, schema: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": [
                "maxOutputTokens": 8_000,
                "responseMimeType": "application/json",
                "responseJsonSchema": schema
            ]
        ])
    }

    static func parseModelList(_ data: Data) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw SmartMarkerProviderError.invalidResponse(
                "Google returned a model list In/Out could not read."
            )
        }
        return models.compactMap { model -> String? in
            let methods = model["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent"),
                  let name = model["name"] as? String else {
                return nil
            }
            return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
        }
    }

    static func outputText(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let candidate = candidates.first,
              let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first else {
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let blockReason = root?["promptFeedback"] as? [String: Any]
            if blockReason?["blockReason"] != nil {
                throw SmartMarkerProviderError.sectionBlocked
            }
            throw SmartMarkerProviderError.invalidResponse(
                "Gemini returned a response In/Out could not read."
            )
        }
        return text
    }

    private func generate(system: String, prompt: String, schema: [String: Any]) async throws
        -> String {
        let body = try Self.requestBody(system: system, prompt: prompt, schema: schema)
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let data = try await perform(
            path: "/v1beta/models/\(encodedModel):generateContent",
            method: "POST",
            body: body
        )
        return try Self.outputText(from: data)
    }

    private func perform(path: String, method: String, body: Data?) async throws -> Data {
        guard let url = URL(string: "https://generativelanguage.googleapis.com\(path)") else {
            throw SmartMarkerProviderError.requestFailed("The Gemini endpoint is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await cloudResponse(
            request: request,
            session: session,
            provider: "Gemini"
        )
    }
}

private func cloudResponse(
    request: URLRequest,
    session: URLSession,
    provider: String
) async throws -> Data {
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await session.data(for: request)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw SmartMarkerProviderError.requestFailed(
            "Could not reach \(provider): \(error.localizedDescription)"
        )
    }
    guard let http = response as? HTTPURLResponse else {
        throw SmartMarkerProviderError.requestFailed(
            "\(provider) returned an invalid network response."
        )
    }
    guard (200..<300).contains(http.statusCode) else {
        let detail = cloudErrorMessage(from: data) ??
            HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        let prefix: String
        switch http.statusCode {
        case 401, 403: prefix = "\(provider) rejected the API key or model access."
        case 429: prefix = "\(provider) rate limit or account quota reached."
        default: prefix = "\(provider) request failed (\(http.statusCode))."
        }
        throw SmartMarkerProviderError.requestFailed("\(prefix) \(detail)")
    }
    return data
}

private func cloudErrorMessage(from data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = root["error"] as? [String: Any] else {
        return nil
    }
    return error["message"] as? String
}
