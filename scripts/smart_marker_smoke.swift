import Foundation

struct TranscriptWordTiming {
    let word: String
    let start: Double
    let end: Double
}

struct TranscriptSegment {
    let id: UUID
    let start: Double
    let end: Double
    let text: String
    let timedWords: [TranscriptWordTiming]

    init(
        id: UUID,
        start: Double,
        end: Double,
        text: String,
        timedWords: [TranscriptWordTiming] = []
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.timedWords = timedWords
    }
}

final class SmartMarkerMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw NSError(domain: "SmartMarkerMockURLProtocol", code: 1)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@main
struct SmartMarkerSmokeTest {
    static func main() async throws {
        let segments = (0..<24).map { index in
            TranscriptSegment(
                id: UUID(),
                start: Double(index * 10),
                end: Double((index + 1) * 10),
                text: "Transcript segment \(index) with enough text to exercise chunking."
            )
        }
        let configuration = SmartMarkerAnalysisConfiguration(
            providerID: .appleIntelligence,
            modelIdentifier: nil,
            recipe: .topicChanges,
            scope: .selectedClip,
            density: .standard,
            preferNearbyPauses: false
        )
        precondition(SmartMarkerRecipe.topicChanges.resultTypeTitle == "Markers")
        precondition(SmartMarkerRecipe.notableExcerpts.resultTypeTitle == "Ranges")
        precondition(SmartMarkerRecipe.youtubeChapters.resultTypeTitle == "Text")
        precondition(SmartMarkerRecipe.youtubeChapters.outputKind == .text)
        precondition(formatSmartMarkerChapterTimestamp(0) == "00:00:00")
        precondition(formatSmartMarkerChapterTimestamp(134) == "00:02:14")
        precondition(formatSmartMarkerChapterTimestamp(3_661) == "01:01:01")
        let customRecipe = SmartMarkerCustomRecipe(
            id: UUID(),
            name: "Fact-Check Candidates",
            summary: "Find claims that should be verified.",
            instructions: "Find consequential factual claims involving numbers, dates, or laws.",
            outputKind: .markers,
            defaultScope: .entireVideo,
            defaultDensity: .more,
            selectionStrategy: .timelineCoverage,
            maximumResults: 9,
            prefersNearbyPauses: false
        )
        let customAnalysisRecipe = SmartMarkerAnalysisRecipe.custom(customRecipe)
        precondition(customAnalysisRecipe.title == "Fact-Check Candidates")
        precondition(customAnalysisRecipe.outputKind == .markers)
        precondition(customAnalysisRecipe.selectionStrategy == .timelineCoverage)
        precondition(
            SmartMarkerProviderPrompt.task(for: customAnalysisRecipe) ==
                customRecipe.instructions
        )
        let adHocPrompt = "Summarize the strongest arguments and unresolved questions."
        let adHocRecipe = SmartMarkerAnalysisRecipe.adHoc(adHocPrompt)
        precondition(adHocRecipe.title == "Ask AI")
        precondition(adHocRecipe.outputKind == .text)
        precondition(adHocRecipe.isDocumentText)
        precondition(adHocRecipe.defaultScope == .entireVideo)
        precondition(SmartMarkerProviderPrompt.task(for: adHocRecipe) == adHocPrompt)
        precondition(
            SmartMarkerProviderPrompt.documentPrompt(
                transcript: "[0] Transcript text.",
                recipe: adHocRecipe
            ).contains(adHocPrompt)
        )
        var descriptionRecipe = SmartMarkerCustomRecipe.newRecipe()
        precondition(descriptionRecipe.name.isEmpty)
        precondition(descriptionRecipe.summary.isEmpty)
        descriptionRecipe.name = "YouTube Description"
        descriptionRecipe.summary = "Write a concise video description."
        descriptionRecipe.instructions = "Write a concise YouTube description of the video."
        descriptionRecipe.outputKind = .text
        descriptionRecipe.textMode = .document
        let descriptionAnalysisRecipe = SmartMarkerAnalysisRecipe.custom(
            descriptionRecipe.normalized
        )
        precondition(descriptionAnalysisRecipe.isDocumentText)
        precondition(descriptionAnalysisRecipe.textMode == .document)
        precondition(
            SmartMarkerProviderPrompt.documentPrompt(
                transcript: "[0] Transcript text.",
                recipe: descriptionAnalysisRecipe
            ).contains("Create the requested final text")
        )
        let encodedDescriptionRecipe = try JSONEncoder().encode(descriptionRecipe.normalized)
        let decodedDescriptionRecipe = try JSONDecoder().decode(
            SmartMarkerCustomRecipe.self,
            from: encodedDescriptionRecipe
        )
        precondition(
            decodedDescriptionRecipe.textMode == .document
        )
        let input = try SmartMarkerAnalyzer.makeInput(
            segments: segments,
            configuration: configuration,
            clipStart: 45,
            clipEnd: 125,
            totalDuration: 240,
            waveformSamples: []
        )

        precondition(input.entries.first?.ordinal == 4, "Scope must retain the segment overlapping its start.")
        precondition(input.entries.last?.ordinal == 12, "Scope must retain the segment overlapping its end.")
        precondition(input.entries.map(\.segmentID) == Array(segments[4...12]).map(\.id))

        let windows = SmartMarkerAnalyzer.makeWindows(
            from: input.entries,
            tokenLimit: 65,
            overlapCount: 2
        )
        precondition(windows.count > 1, "A constrained character budget should produce multiple windows.")
        for pair in zip(windows, windows.dropFirst()) {
            let overlap = Set(pair.0.suffix(2).map(\.segmentID))
            precondition(!overlap.isDisjoint(with: pair.1.map(\.segmentID)), "Adjacent windows must overlap.")
        }
        precondition(
            SmartMarkerAnalyzer.estimatedTokenCount(String(repeating: "a", count: 12)) == 4,
            "Latin text should use Apple's conservative three-characters-per-token estimate."
        )
        precondition(
            SmartMarkerAnalyzer.estimatedTokenCount(String(repeating: "界", count: 12)) == 12,
            "Multibyte text should reserve approximately one token per character."
        )

        let timedSegmentID = UUID()
        let timedWords = [
            ("First", 20.0, 20.4),
            ("thought", 20.4, 20.9),
            ("ends.", 20.9, 21.3),
            ("A", 21.7, 21.9),
            ("different", 21.9, 22.4),
            ("topic", 22.4, 22.8),
            ("starts", 22.8, 23.2),
            ("here", 23.2, 23.6),
            ("now.", 23.6, 24.0)
        ].map {
            TranscriptWordTiming(word: $0.0, start: $0.1, end: $0.2)
        }
        let timedSegment = TranscriptSegment(
            id: timedSegmentID,
            start: 20,
            end: 24,
            text: "First thought ends. A different topic starts here now.",
            timedWords: timedWords
        )
        let granularEntries = SmartMarkerAnalyzer.analysisEntries(
            for: timedSegment,
            startingOrdinal: 40
        )
        precondition(granularEntries.count > 1, "Timed words should produce sub-line anchors.")
        precondition(granularEntries.first?.ordinal == 40)
        precondition(granularEntries.allSatisfy { $0.segmentID == timedSegmentID })
        precondition(
            granularEntries.map(\.text).joined(separator: " ") == timedSegment.text,
            "Granular analysis text must exactly reconstruct the displayed segment text."
        )
        precondition(
            granularEntries.dropFirst().first?.start == 21.7,
            "A granular anchor must retain the first word's timestamp."
        )

        let mismatchedSegment = TranscriptSegment(
            id: UUID(),
            start: 30,
            end: 35,
            text: "The displayed transcript remains authoritative.",
            timedWords: [
                TranscriptWordTiming(word: "Different", start: 30, end: 31),
                TranscriptWordTiming(word: "words", start: 31, end: 32)
            ]
        )
        let fallbackEntries = SmartMarkerAnalyzer.analysisEntries(
            for: mismatchedSegment,
            startingOrdinal: 50
        )
        precondition(fallbackEntries.count == 1)
        precondition(fallbackEntries[0].text == mismatchedSegment.text)
        precondition(fallbackEntries[0].start == mismatchedSegment.start)

        let parsed = SmartMarkerAnalyzer.parseMarkerResponse(
            """
            MARKER	12	Campaign strategy	Conversation changes to electoral tactics.
            MARKER|[15]|Strong quote|A concise statement of the central argument.
            2|18|Policy shift|The discussion moves to a different policy.
            This malformed line must be ignored.
            """
        )
        precondition(parsed.count == 3, "The permissive text response parser must reject malformed lines.")
        precondition(parsed.map(\.segmentID) == [12, 15, 18])
        precondition(parsed[0].label == "Campaign strategy")

        let parsedRanges = SmartMarkerProviderPrompt.parseAppleResponse(
            """
            RANGE|4|8|Complete answer|A self-contained explanation worth clipping.
            RANGE|10|9|Invalid range|The end must occur after the start.
            MARKER|11|Wrong shape|Point markers are invalid for a range recipe.
            """,
            recipe: .notableExcerpts
        )
        precondition(parsedRanges.count == 1, "Range parsing must reject reversed and point rows.")
        precondition(parsedRanges[0].segmentID == 4)
        precondition(parsedRanges[0].endSegmentID == 8)
        let chapterPrompt = SmartMarkerProviderPrompt.cloudPrompt(
            transcript: "[0] Opening section.",
            recipe: .youtubeChapters,
            limit: 8
        )
        precondition(chapterPrompt.contains("chronological order"))
        precondition(chapterPrompt.contains("end_segment_id to null"))
        precondition(chapterPrompt.contains("display text in label"))
        precondition(chapterPrompt.contains("ad break clearly identifies its sponsor"))
        precondition(chapterPrompt.contains("Avoid guessing the spelling"))
        precondition(chapterPrompt.contains("cover the entire transcript"))
        let timestampedTranscript = SmartMarkerProviderPrompt.transcript(
            from: [
                SmartMarkerTranscriptEntry(
                    ordinal: 7,
                    segmentID: UUID(),
                    start: 134,
                    end: 140,
                    text: "The discussion turns to housing."
                )
            ],
            recipe: .youtubeChapters
        )
        precondition(
            timestampedTranscript == "[7] [00:02:14] The discussion turns to housing."
        )

        let openAIPayload = """
        {
          "markers": [
            {
              "segment_id": 12,
              "end_segment_id": null,
              "label": "Campaign strategy",
              "explanation": "The discussion moves to electoral tactics.",
              "relevance_score": 94
            },
            {
              "segment_id": 20,
              "end_segment_id": 24,
              "label": "Complete answer",
              "explanation": "A self-contained passage suitable for a clip.",
              "relevance_score": 91
            }
          ]
        }
        """
        let openAIEnvelope = try JSONSerialization.data(
            withJSONObject: [
                "output": [
                    [
                        "content": [
                            [
                                "type": "output_text",
                                "text": openAIPayload
                            ]
                        ]
                    ]
                ]
            ]
        )
        let openAIMarkers = try OpenAIResponsesClient.parseMarkerResponse(openAIEnvelope)
        precondition(openAIMarkers.count == 2)
        precondition(openAIMarkers[0].segmentID == 12)
        precondition(openAIMarkers[0].endSegmentID == nil)
        precondition(openAIMarkers[0].relevanceScore == 94)
        precondition(openAIMarkers[1].segmentID == 20)
        precondition(openAIMarkers[1].endSegmentID == 24)
        let documentPayload = """
        {
          "text": "A concise description of the video.\\n\\nThe discussion covers housing policy."
        }
        """
        let documentEnvelope = try JSONSerialization.data(
            withJSONObject: [
                "output": [
                    [
                        "content": [
                            [
                                "type": "output_text",
                                "text": documentPayload
                            ]
                        ]
                    ]
                ]
            ]
        )
        let parsedDocument = try OpenAIResponsesClient.parseDocumentResponse(documentEnvelope)
        precondition(
            parsedDocument ==
                "A concise description of the video.\n\nThe discussion covers housing policy."
        )
        let documentRequestBody = try OpenAIResponsesClient.documentRequestBody(
            model: "chat-latest",
            transcript: "[0] Transcript text.",
            recipe: descriptionAnalysisRecipe
        )
        let documentRequestJSON = try JSONSerialization.jsonObject(
            with: documentRequestBody
        ) as? [String: Any]
        let documentTextConfig = documentRequestJSON?["text"] as? [String: Any]
        let documentFormat = documentTextConfig?["format"] as? [String: Any]
        let documentSchema = documentFormat?["schema"] as? [String: Any]
        let documentProperties = documentSchema?["properties"] as? [String: Any]
        precondition(documentProperties?["text"] != nil)
        precondition(documentRequestJSON?["store"] as? Bool == false)

        let refinementContext = SmartMarkerRefinementContext(
            entries: input.entries,
            scopeStart: input.scopeStart,
            scopeEnd: input.scopeEnd,
            totalDuration: input.totalDuration
        )
        let currentSuggestion = SmartMarkerSuggestion(
            sourceSegmentID: input.entries[1].segmentID,
            seconds: input.entries[1].start,
            category: configuration.recipe.markerCategory,
            label: "Current result",
            explanation: "The existing suggestion."
        )
        let refinementRequest = SmartMarkerRefinementRequest(
            entries: input.entries,
            recipe: configuration.recipe,
            currentSuggestions: [currentSuggestion],
            currentDocumentText: "",
            conversation: [
                SmartMarkerRefinementMessage(
                    role: .assistant,
                    text: "I found one useful transition."
                )
            ],
            instruction: "Move it to the later transition.",
            maximumResults: 4
        )
        let refinementPrompt = SmartMarkerProviderPrompt.refinementPrompt(
            for: refinementRequest
        )
        precondition(refinementPrompt.contains("Current result"))
        precondition(refinementPrompt.contains("I found one useful transition."))
        precondition(refinementPrompt.contains("Move it to the later transition."))
        precondition(refinementPrompt.contains(input.entries.last!.text))

        let granularRefinementRequest = SmartMarkerRefinementRequest(
            entries: granularEntries,
            recipe: configuration.recipe,
            currentSuggestions: [
                SmartMarkerSuggestion(
                    sourceSegmentID: timedSegmentID,
                    seconds: granularEntries.last!.start,
                    category: configuration.recipe.markerCategory,
                    label: "Granular result",
                    explanation: "Uses a word-level transcript anchor."
                )
            ],
            currentDocumentText: "",
            conversation: [],
            instruction: "Explain this result.",
            maximumResults: 4
        )
        let granularRefinementPrompt = SmartMarkerProviderPrompt.refinementPrompt(
            for: granularRefinementRequest
        )
        precondition(
            granularRefinementPrompt.contains(
                "segment_id=\(granularEntries.last!.ordinal) | Granular result"
            ),
            "Refinement must safely resolve duplicate source segment IDs to the nearest granular anchor."
        )

        let conversationalRefinement = try SmartMarkerProviderPrompt.parseRefinementJSON(
            """
            ```json
            {
              "action": "message",
              "message": "The current marker is near the strongest transition.",
              "document_text": null,
              "suggestions": []
            }
            ```
            """
        )
        precondition(conversationalRefinement.action == .message)
        precondition(conversationalRefinement.suggestions.isEmpty)
        precondition(
            conversationalRefinement.message ==
                "The current marker is near the strongest transition."
        )

        let replacementJSON = """
        {
          "action": "replace",
          "message": "I moved the marker later.",
          "document_text": null,
          "suggestions": [
            {
              "segment_id": \(input.entries[3].ordinal),
              "end_segment_id": null,
              "label": "Later transition",
              "explanation": "The subject changes here.",
              "relevance_score": 96
            }
          ]
        }
        """
        let replacementRefinement = try SmartMarkerProviderPrompt.parseRefinementJSON(
            replacementJSON
        )
        let resolvedReplacement = try SmartMarkerAnalyzer.resolveRefinementSuggestions(
            replacementRefinement.suggestions,
            context: refinementContext,
            configuration: configuration
        )
        precondition(resolvedReplacement.count == 1)
        precondition(resolvedReplacement[0].seconds == input.entries[3].start)
        precondition(
            resolvedReplacement[0].sourceSegmentID == input.entries[3].segmentID
        )
        do {
            _ = try SmartMarkerAnalyzer.resolveRefinementSuggestions(
                [
                    SmartMarkerGeneratedCandidate(
                        segmentID: Int.max,
                        label: "Invalid",
                        explanation: "This anchor is not in the transcript.",
                        relevanceScore: 100
                    )
                ],
                context: refinementContext,
                configuration: configuration
            )
            preconditionFailure("Unknown transcript anchors must not replace current results.")
        } catch SmartMarkerAnalysisError.noSuggestions {
            // Expected.
        }

        let refinementRequestBody = try OpenAIResponsesClient.refinementRequestBody(
            model: "chat-latest",
            request: refinementRequest
        )
        let refinementRequestJSON = try JSONSerialization.jsonObject(
            with: refinementRequestBody
        ) as? [String: Any]
        precondition(refinementRequestJSON?["store"] as? Bool == false)
        let refinementText = refinementRequestJSON?["text"] as? [String: Any]
        let refinementFormat = refinementText?["format"] as? [String: Any]
        let refinementSchema = refinementFormat?["schema"] as? [String: Any]
        let refinementProperties = refinementSchema?["properties"] as? [String: Any]
        let actionSchema = refinementProperties?["action"] as? [String: Any]
        precondition(actionSchema?["enum"] as? [String] == ["message", "replace"])
        let suggestionsSchema = refinementProperties?["suggestions"] as? [String: Any]
        precondition(suggestionsSchema?["maxItems"] as? Int == 4)

        let refinementEnvelope = try JSONSerialization.data(
            withJSONObject: [
                "output": [
                    [
                        "content": [
                            [
                                "type": "output_text",
                                "text": replacementJSON
                            ]
                        ]
                    ]
                ]
            ]
        )
        let parsedOpenAIRefinement = try OpenAIResponsesClient.parseRefinementResponse(
            refinementEnvelope
        )
        precondition(parsedOpenAIRefinement == replacementRefinement)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SmartMarkerMockURLProtocol.self]
        let mockSession = URLSession(configuration: sessionConfiguration)
        let modelListData = try JSONSerialization.data(
            withJSONObject: [
                "object": "list",
                "data": [
                    ["id": "gpt-5.6-terra", "object": "model"],
                    ["id": "chat-latest", "object": "model"],
                    ["id": "gpt-4.1-mini", "object": "model"],
                    ["id": "gpt-5.6-terra-2026-07-15", "object": "model"],
                    ["id": "gpt-4o-realtime-preview", "object": "model"],
                    ["id": "text-embedding-3-large", "object": "model"]
                ]
            ]
        )
        let listedModelIDs = try OpenAIResponsesClient.parseModelList(modelListData)
        let modelOptions = SmartMarkerOpenAIModelCatalog.options(from: listedModelIDs)
        precondition(
            modelOptions.map(\.id) == [
                "gpt-5.6-terra",
                "chat-latest",
                "gpt-4.1-mini"
            ],
            "The model picker must prioritize recommended models and omit incompatible models."
        )
        precondition(modelOptions[0].isRecommended)
        precondition(!modelOptions[2].isRecommended)
        precondition(
            !SmartMarkerOpenAIModelCatalog.isCompatibleAlias(
                "gpt-5.6-terra-2026-07-15"
            ),
            "Dated snapshots should remain available through Custom Model ID, not clutter the picker."
        )
        SmartMarkerMockURLProtocol.handler = { request in
            precondition(request.url?.absoluteString == "https://api.openai.com/v1/models")
            precondition(request.httpMethod == "GET")
            precondition(request.httpBody == nil)
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, modelListData)
        }
        let fetchedModelIDs = try await OpenAIResponsesClient(
            apiKey: "test-key",
            model: "chat-latest",
            session: mockSession
        ).listModels()
        precondition(fetchedModelIDs == listedModelIDs)

        let requestBody = try OpenAIResponsesClient.markerRequestBody(
            model: "chat-latest",
            transcript: "[12] The discussion moves to campaign strategy.",
            recipe: .adBreaks,
            limit: 3
        )
        let requestJSON = try JSONSerialization.jsonObject(
            with: requestBody
        ) as? [String: Any]
        precondition(requestJSON?["model"] as? String == "chat-latest")
        precondition(requestJSON?["store"] as? Bool == false)
        let requestText = requestJSON?["text"] as? [String: Any]
        let requestFormat = requestText?["format"] as? [String: Any]
        precondition(requestFormat?["type"] as? String == "json_schema")
        let schema = requestFormat?["schema"] as? [String: Any]
        let schemaProperties = schema?["properties"] as? [String: Any]
        let markersSchema = schemaProperties?["markers"] as? [String: Any]
        let markerItems = markersSchema?["items"] as? [String: Any]
        let markerProperties = markerItems?["properties"] as? [String: Any]
        let endSegmentSchema = markerProperties?["end_segment_id"] as? [String: Any]
        let endSegmentTypes = endSegmentSchema?["type"] as? [String]
        let requiredMarkerFields = markerItems?["required"] as? [String]
        precondition(Set(endSegmentTypes ?? []) == Set(["integer", "null"]))
        precondition(requiredMarkerFields?.contains("end_segment_id") == true)

        let rangeSuggestion = SmartMarkerSuggestion(
            sourceSegmentID: UUID(),
            seconds: 30,
            endSeconds: 42.5,
            category: "Notable excerpt",
            label: "Complete answer",
            explanation: "A self-contained passage."
        )
        precondition(rangeSuggestion.duration == 12.5)
        precondition(
            rangeSuggestion.navigationSeconds == [30, 42.5],
            "Range navigation must include both the start and end."
        )
        let pointSuggestion = SmartMarkerSuggestion(
            sourceSegmentID: UUID(),
            seconds: 30,
            category: "Highlight",
            label: "Strong quote",
            explanation: "A useful point."
        )
        precondition(
            pointSuggestion.navigationSeconds == [30],
            "Point navigation must continue to contribute only its marker time."
        )
        let chapterConfiguration = SmartMarkerAnalysisConfiguration(
            providerID: .openAI,
            modelIdentifier: nil,
            recipe: .youtubeChapters,
            scope: .entireVideo,
            density: .standard,
            preferNearbyPauses: false
        )
        let customConfiguration = SmartMarkerAnalysisConfiguration(
            providerID: .openAI,
            modelIdentifier: nil,
            recipe: customAnalysisRecipe,
            scope: .entireVideo,
            density: .more,
            preferNearbyPauses: false
        )
        precondition(
            SmartMarkerAnalyzer.targetSuggestionCount(
                duration: 3_600,
                configuration: customConfiguration
            ) == 9,
            "A custom maximum must cap the density-derived result count."
        )
        let chapterSuggestions = SmartMarkerAnalyzer.preparedSuggestions(
            [
                SmartMarkerSuggestion(
                    sourceSegmentID: UUID(),
                    seconds: 6.4,
                    category: "Chapter",
                    label: "Introduction",
                    explanation: "Opening section."
                ),
                SmartMarkerSuggestion(
                    sourceSegmentID: UUID(),
                    seconds: 134,
                    category: "Chapter",
                    label: "Housing policy",
                    explanation: "The discussion turns to housing."
                )
            ],
            limit: 8,
            configuration: chapterConfiguration,
            scopeStart: 0,
            scopeEnd: 240
        )
        precondition(chapterSuggestions.first?.seconds == 0)
        precondition(chapterSuggestions.first?.label == "Introduction")
        precondition(chapterSuggestions.last?.seconds == 134)
        precondition(
            chapterSuggestions.map(smartMarkerTextLine).joined(separator: "\n") ==
                "00:00:00 Introduction\n00:02:14 Housing policy",
            "Copied text output must omit internal categories and explanations."
        )
        var chapterHistoryTab = SmartMarkerAnalysisTab(
            id: UUID(),
            title: "YouTube Chapters",
            configuration: chapterConfiguration,
            suggestions: [chapterSuggestions[1]],
            documentText: "",
            refinementContext: nil,
            refinementMessages: [],
            refinementRevisions: [
                SmartMarkerResultSnapshot(
                    suggestions: chapterSuggestions,
                    documentText: ""
                )
            ],
            currentResultRefinementInstruction: "Use fewer chapters.",
            selectedResultVersionIndex: 0,
            isRefining: false,
            refinementErrorText: "",
            deletedSuggestionIDs: [],
            highlightedSuggestionID: nil,
            scrollPositionSuggestionID: nil,
            isAnalyzing: false,
            completedWindows: 1,
            totalWindows: 1,
            skippedWindowCount: 0,
            errorText: ""
        )
        precondition(chapterHistoryTab.supportsResultHistory)
        precondition(!chapterHistoryTab.isViewingCurrentResult)
        precondition(chapterHistoryTab.displayedResult.suggestions == chapterSuggestions)
        chapterHistoryTab.selectResultVersion(1)
        precondition(chapterHistoryTab.isViewingCurrentResult)
        precondition(chapterHistoryTab.displayedResult.suggestions == [chapterSuggestions[1]])
        precondition(
            chapterHistoryTab.displayedResult.refinementInstruction == "Use fewer chapters."
        )
        chapterHistoryTab.selectResultVersion(-1)
        precondition(chapterHistoryTab.resolvedResultVersionIndex == 0)
        precondition(
            SmartMarkerAnalyzer.targetSuggestionCount(
                duration: 30 * 60,
                configuration: chapterConfiguration
            ) <= 6
        )
        precondition(
            SmartMarkerAnalyzer.targetSuggestionCount(
                duration: 31 * 60,
                configuration: SmartMarkerAnalysisConfiguration(
                    providerID: .openAI,
                    modelIdentifier: nil,
                    recipe: .youtubeChapters,
                    scope: .entireVideo,
                    density: .more,
                    preferNearbyPauses: false
                )
            ) == 12
        )
        let distributedCandidates = (0..<12).map { index in
            SmartMarkerSuggestion(
                sourceSegmentID: UUID(),
                seconds: Double(index * 300 + 30),
                category: "Chapter",
                label: "Section \(index)",
                explanation: "Section \(index).",
                relevanceScore: Double(100 - index)
            )
        }
        let distributedChapters = SmartMarkerAnalyzer.preparedSuggestions(
            distributedCandidates,
            limit: 6,
            configuration: chapterConfiguration,
            scopeStart: 0,
            scopeEnd: 3_600
        )
        precondition(distributedChapters.count == 6)
        precondition(
            distributedChapters.filter { $0.seconds < 1_200 }.count == 2
        )
        precondition(
            distributedChapters.filter { $0.seconds >= 1_200 && $0.seconds < 2_400 }.count == 2
        )
        precondition(
            distributedChapters.filter { $0.seconds >= 2_400 }.count == 2,
            "Chapter selection must reserve capacity for the final third."
        )
        let distributedCustomMarkers = SmartMarkerAnalyzer.preparedSuggestions(
            distributedCandidates,
            limit: 6,
            configuration: customConfiguration,
            scopeStart: 0,
            scopeEnd: 3_600
        )
        precondition(distributedCustomMarkers.count == 6)
        precondition(
            distributedCustomMarkers.filter { $0.seconds >= 2_400 }.count == 2,
            "Custom timeline-coverage recipes must reserve capacity for the final third."
        )
        precondition(
            distributedCustomMarkers.first?.seconds == distributedCandidates.first?.seconds,
            "Only YouTube Chapters may rewrite the opening timestamp."
        )

        SmartMarkerMockURLProtocol.handler = { request in
            precondition(request.url?.absoluteString == "https://api.openai.com/v1/responses")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, openAIEnvelope)
        }
        let mockMarkers = try await OpenAIResponsesClient(
            apiKey: "test-key",
            model: "chat-latest",
            session: mockSession
        ).generateMarkers(
            transcript: "[12] The discussion moves to campaign strategy.",
            recipe: .adBreaks,
            limit: 3
        )
        precondition(mockMarkers == openAIMarkers)

        let claudeBody = try ClaudeMessagesClient.requestBody(
            model: "claude-sonnet-4-6",
            system: ClaudeMessagesClient.markerSystemPrompt,
            prompt: "Analyze this transcript.",
            schema: SmartMarkerStructuredOutput.markerSchema(limit: 3)
        )
        let claudeBodyJSON = try JSONSerialization.jsonObject(with: claudeBody)
            as? [String: Any]
        let claudeOutputConfig = claudeBodyJSON?["output_config"] as? [String: Any]
        let claudeFormat = claudeOutputConfig?["format"] as? [String: Any]
        precondition(claudeFormat?["type"] as? String == "json_schema")
        let claudeSchema = claudeFormat?["schema"] as? [String: Any]
        let claudeProperties = claudeSchema?["properties"] as? [String: Any]
        let claudeMarkersSchema = claudeProperties?["markers"] as? [String: Any]
        precondition(claudeMarkersSchema?["maxItems"] == nil)
        let claudeMarkerItem = claudeMarkersSchema?["items"] as? [String: Any]
        let claudeMarkerProperties = claudeMarkerItem?["properties"] as? [String: Any]
        let claudeRelevanceSchema = claudeMarkerProperties?["relevance_score"]
            as? [String: Any]
        precondition(claudeRelevanceSchema?["minimum"] == nil)
        precondition(claudeRelevanceSchema?["maximum"] == nil)

        let claudeRefinementBody = try ClaudeMessagesClient.requestBody(
            model: "claude-sonnet-4-6",
            system: ClaudeMessagesClient.refinementSystemPrompt,
            prompt: "Refine these suggestions.",
            schema: SmartMarkerStructuredOutput.refinementSchema(maximumResults: 4)
        )
        let claudeRefinementJSON = try JSONSerialization.jsonObject(
            with: claudeRefinementBody
        ) as? [String: Any]
        let claudeRefinementOutput = claudeRefinementJSON?["output_config"] as? [String: Any]
        let claudeRefinementFormat = claudeRefinementOutput?["format"] as? [String: Any]
        let claudeRefinementSchema = claudeRefinementFormat?["schema"] as? [String: Any]
        let claudeRefinementProperties = claudeRefinementSchema?["properties"]
            as? [String: Any]
        let claudeSuggestionsSchema = claudeRefinementProperties?["suggestions"]
            as? [String: Any]
        precondition(claudeSuggestionsSchema?["maxItems"] == nil)
        let claudeEnvelope = try JSONSerialization.data(withJSONObject: [
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "content": [["type": "text", "text": openAIPayload]],
            "model": "claude-sonnet-4-6",
            "stop_reason": "end_turn"
        ])
        SmartMarkerMockURLProtocol.handler = { request in
            precondition(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            precondition(request.httpMethod == "POST")
            precondition(request.value(forHTTPHeaderField: "x-api-key") == "claude-test-key")
            precondition(
                request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01"
            )
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, claudeEnvelope)
        }
        let claudeMarkers = try await ClaudeMessagesClient(
            apiKey: "claude-test-key",
            model: "claude-sonnet-4-6",
            session: mockSession
        ).generateMarkers(
            transcript: "[12] The discussion moves to campaign strategy.",
            recipe: .adBreaks,
            limit: 3
        )
        precondition(claudeMarkers == openAIMarkers)

        let claudeModelsData = try JSONSerialization.data(withJSONObject: [
            "data": [
                ["type": "model", "id": "claude-haiku-4-5"],
                ["type": "model", "id": "claude-sonnet-4-6"],
                ["type": "model", "id": "unrelated-model"]
            ],
            "has_more": false
        ])
        let claudeModelIDs = try ClaudeMessagesClient.parseModelList(claudeModelsData)
        precondition(claudeModelIDs.count == 3)
        precondition(
            SmartMarkerClaudeModelCatalog.options(from: claudeModelIDs).map(\.id) == [
                "claude-sonnet-4-6",
                "claude-haiku-4-5"
            ]
        )
        SmartMarkerMockURLProtocol.handler = { request in
            precondition(
                request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000"
            )
            precondition(request.httpMethod == "GET")
            precondition(request.value(forHTTPHeaderField: "x-api-key") == "claude-test-key")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, claudeModelsData)
        }
        let fetchedClaudeModels = try await ClaudeMessagesClient(
            apiKey: "claude-test-key",
            model: "claude-sonnet-4-6",
            session: mockSession
        ).listModels()
        precondition(fetchedClaudeModels == claudeModelIDs)

        let geminiBody = try GeminiGenerateContentClient.requestBody(
            system: ClaudeMessagesClient.markerSystemPrompt,
            prompt: "Analyze this transcript.",
            schema: SmartMarkerStructuredOutput.markerSchema(limit: 3)
        )
        let geminiBodyJSON = try JSONSerialization.jsonObject(with: geminiBody)
            as? [String: Any]
        let geminiGenerationConfig = geminiBodyJSON?["generationConfig"] as? [String: Any]
        precondition(
            geminiGenerationConfig?["responseMimeType"] as? String == "application/json"
        )
        precondition(geminiGenerationConfig?["responseJsonSchema"] != nil)
        let geminiEnvelope = try JSONSerialization.data(withJSONObject: [
            "candidates": [
                [
                    "content": [
                        "role": "model",
                        "parts": [["text": openAIPayload]]
                    ],
                    "finishReason": "STOP"
                ]
            ]
        ])
        SmartMarkerMockURLProtocol.handler = { request in
            precondition(
                request.url?.absoluteString ==
                    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent"
            )
            precondition(request.httpMethod == "POST")
            precondition(request.value(forHTTPHeaderField: "x-goog-api-key") == "gemini-test-key")
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, geminiEnvelope)
        }
        let geminiMarkers = try await GeminiGenerateContentClient(
            apiKey: "gemini-test-key",
            model: "gemini-3.6-flash",
            session: mockSession
        ).generateMarkers(
            transcript: "[12] The discussion moves to campaign strategy.",
            recipe: .adBreaks,
            limit: 3
        )
        precondition(geminiMarkers == openAIMarkers)

        let geminiModelsData = try JSONSerialization.data(withJSONObject: [
            "models": [
                [
                    "name": "models/gemini-2.5-flash",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/gemini-3.6-flash",
                    "supportedGenerationMethods": ["generateContent"]
                ],
                [
                    "name": "models/text-embedding-004",
                    "supportedGenerationMethods": ["embedContent"]
                ]
            ]
        ])
        let geminiModelIDs = try GeminiGenerateContentClient.parseModelList(geminiModelsData)
        precondition(geminiModelIDs == ["gemini-2.5-flash", "gemini-3.6-flash"])
        precondition(
            SmartMarkerGeminiModelCatalog.options(from: geminiModelIDs).map(\.id) == [
                "gemini-3.6-flash",
                "gemini-2.5-flash"
            ]
        )
        SmartMarkerMockURLProtocol.handler = { request in
            precondition(
                request.url?.absoluteString ==
                    "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"
            )
            precondition(request.httpMethod == "GET")
            precondition(request.value(forHTTPHeaderField: "x-goog-api-key") == "gemini-test-key")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, geminiModelsData)
        }
        let fetchedGeminiModels = try await GeminiGenerateContentClient(
            apiKey: "gemini-test-key",
            model: "gemini-3.6-flash",
            session: mockSession
        ).listModels()
        precondition(fetchedGeminiModels == geminiModelIDs)
        SmartMarkerMockURLProtocol.handler = nil
        mockSession.invalidateAndCancel()

        await MainActor.run {
            let storeDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("in-out-recipe-store-\(UUID().uuidString)")
            let storeURL = storeDirectory.appendingPathComponent("recipes.json")
            let recipeStore = SmartMarkerRecipeStore(fileURL: storeURL)
            recipeStore.save(customRecipe)
            precondition(recipeStore.customRecipes == [customRecipe])
            recipeStore.duplicate(customRecipe)
            precondition(recipeStore.customRecipes.count == 2)
            precondition(
                recipeStore.customRecipes.contains { $0.name == "Fact-Check Candidates Copy" }
            )
            recipeStore.setHidden(true, for: .highlights)
            precondition(recipeStore.isHidden(.highlights))
            precondition(!recipeStore.isHidden(.topicChanges))
            let reloadedStore = SmartMarkerRecipeStore(fileURL: storeURL)
            precondition(reloadedStore.customRecipes.count == 2)
            precondition(reloadedStore.isHidden(.highlights))
            reloadedStore.setHidden(false, for: .highlights)
            precondition(!reloadedStore.isHidden(.highlights))
            reloadedStore.delete(customRecipe.id)
            precondition(reloadedStore.customRecipes.count == 1)
            try? FileManager.default.removeItem(at: storeDirectory)

            let tabModel = SmartMarkerPresentationModel()
            tabModel.start(
                segments: [],
                configuration: configuration,
                clipStart: 0,
                clipEnd: 10,
                totalDuration: 10,
                waveformSamples: []
            )
            precondition(tabModel.tabs.count == 1)
            precondition(tabModel.tabs[0].title == "Topic Changes")
            precondition(tabModel.tabs[0].errorText == SmartMarkerAnalysisError.noTranscriptInScope.localizedDescription)
            precondition(tabModel.activeTabID == tabModel.tabs[0].id)
            precondition(!tabModel.isAnalyzing)

            let firstTabID = tabModel.tabs[0].id
            tabModel.start(
                segments: [],
                configuration: configuration,
                clipStart: 0,
                clipEnd: 10,
                totalDuration: 10,
                waveformSamples: []
            )
            precondition(tabModel.tabs.count == 2)
            precondition(tabModel.tabs[1].title == "Topic Changes 2")
            let secondTabID = tabModel.tabs[1].id
            tabModel.setScrollPosition(UUID(), for: firstTabID)
            tabModel.selectTab(firstTabID)
            precondition(tabModel.activeTabID == firstTabID)
            precondition(tabModel.tabs[0].scrollPositionSuggestionID != nil)
            tabModel.closeTab(firstTabID)
            precondition(tabModel.tabs.count == 1)
            precondition(tabModel.activeTabID == secondTabID)
            tabModel.closeTab(secondTabID)
            precondition(tabModel.tabs.isEmpty)
            precondition(tabModel.activeTabID == nil)
            precondition(!tabModel.showsSuggestions)
        }

        print("Smart marker smoke test passed (\(input.entries.count) scoped segments, \(windows.count) windows).")

        if CommandLine.arguments.contains("--live") {
            if let unavailable = SmartMarkerAnalyzer.availabilityMessage(for: .appleIntelligence) {
                throw NSError(
                    domain: "SmartMarkerSmokeTest",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: unavailable]
                )
            }

            let newsSegments = [
                "The senator opened by discussing the election and the state of the campaign.",
                "The conversation moved to the war and reports of an attack overnight.",
                "Officials said three people were killed, while investigators continued gathering evidence.",
                "The guest criticized the administration's response and called for congressional oversight.",
                "After a short break, the host changed subjects to campaign finance.",
                "They discussed fundraising totals and advertising planned for the final weeks.",
                "The interview concluded with a question about voter turnout.",
                "The guest summarized the campaign's closing argument."
            ].enumerated().map { index, text in
                TranscriptSegment(
                    id: UUID(),
                    start: Double(index * 30),
                    end: Double((index + 1) * 30),
                    text: text
                )
            }
            let liveInput = try SmartMarkerAnalyzer.makeInput(
                segments: newsSegments,
                configuration: configuration,
                clipStart: 0,
                clipEnd: 240,
                totalDuration: 240,
                waveformSamples: []
            )
            let outcome: SmartMarkerAnalysisOutcome
            do {
                outcome = try await SmartMarkerAnalyzer.analyze(
                    input: liveInput,
                    configuration: configuration
                ) { _, _, _, _ in }
            } catch SmartMarkerAnalysisError.noSuggestions {
                // On-device generation is nondeterministic and may occasionally return NONE.
                outcome = try await SmartMarkerAnalyzer.analyze(
                    input: liveInput,
                    configuration: configuration
                ) { _, _, _, _ in }
            }
            precondition(!outcome.suggestions.isEmpty, "Live political-news analysis should return markers.")
            print(
                "Live Apple Intelligence smoke test passed " +
                    "(\(outcome.suggestions.count) suggestions, \(outcome.skippedSectionCount) skipped)."
            )
        }

    }
}
