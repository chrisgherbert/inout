import Foundation

struct TranscriptCleanupBatch: Sendable {
    let range: Range<Int>
    let contextRange: Range<Int>
    var splitDepth: Int = 0
}

struct TranscriptCleanupExecutionPlan: Sendable {
    let maximumInputBytes: Int
    let maximumWords: Int?
    let concurrency: Int
    let minimumRetryWords: Int
    var maximumSplitDepth: Int = 1
    var indexesEveryWord: Bool = true

    static let local = TranscriptCleanupExecutionPlan(
        maximumInputBytes: 8_000, maximumWords: 60, concurrency: 1, minimumRetryWords: 60
    )

    static func cloud(tokenLimit: Int, glossary: String) -> Self {
        // Conservative estimate for English transcript paragraphs. Leave space for instructions,
        // segment ranges, the glossary, and correction output. This is a budget, not a
        // claim about the context window of a custom model chosen in Settings.
        let availableTokens = max(1_000, tokenLimit - 12_000)
        return Self(maximumInputBytes: max(3_000, availableTokens * 3 - glossary.utf8.count - 6_000),
                    maximumWords: nil, concurrency: 3, minimumRetryWords: 300, indexesEveryWord: false)
    }
}

enum TranscriptCleanupExecution {
    private enum BatchResult: Sendable {
        case completed(TranscriptCleanupBatch, [TranscriptCleanupEdit])
        case split(TranscriptCleanupBatch)
    }

    static func batches(words: [TranscriptCleanupWord], plan: TranscriptCleanupExecutionPlan) -> [TranscriptCleanupBatch] {
        var batches: [TranscriptCleanupBatch] = []
        var start = 0
        while start < words.count {
            var end = start
            var bytes = 0
            while end < words.count {
                let startsSegment = end == 0 || words[end - 1].segmentIndex != words[end].segmentIndex
                let referenceBytes = plan.indexesEveryWord ? String(end).count + 3
                    : (startsSegment ? String(words[end].segmentIndex).count * 2 + 8 : 0)
                let nextBytes = words[end].timing.word.utf8.count + 1 + referenceBytes
                if end > start && (bytes + nextBytes > plan.maximumInputBytes ||
                                   end - start >= (plan.maximumWords ?? Int.max)) { break }
                bytes += nextBytes
                end += 1
            }
            if end < words.count {
                end = segmentBoundary(near: end, after: start, words: words)
            }
            batches.append(batch(start..<end, wordCount: words.count))
            start = end
        }
        return batches
    }

    private static func batch(_ range: Range<Int>, wordCount: Int) -> TranscriptCleanupBatch {
        TranscriptCleanupBatch(range: range,
                               contextRange: max(0, range.lowerBound - 10)..<min(wordCount, range.upperBound + 10))
    }

    private static func segmentBoundary(near end: Int, after start: Int, words: [TranscriptCleanupWord]) -> Int {
        var boundary = end
        let minimum = start + max(1, (end - start) / 2)
        while boundary > minimum && words[boundary - 1].segmentIndex == words[end].segmentIndex {
            boundary -= 1
        }
        return words[boundary - 1].segmentIndex != words[end].segmentIndex ? boundary : end
    }

    static func suggest(
        words: [TranscriptCleanupWord],
        plan: TranscriptCleanupExecutionPlan,
        generate: @escaping @Sendable (TranscriptCleanupBatch) async throws -> String,
        parse: @escaping @Sendable (String, [TranscriptCleanupWord], Range<Int>) async throws -> [TranscriptCleanupEdit] = { try TranscriptCleanup.parse($0, words: $1, allowedRange: $2) },
        onProgress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in },
        onDiagnostics: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> [TranscriptCleanupEdit] {
        try Task.checkCancellation()
        let initialBatches = batches(words: words, plan: plan)
        await onProgress(0, words.count)
        await onDiagnostics("Cleanup: \(words.count) words, \(initialBatches.count) initial request(s)")
        return try await withThrowingTaskGroup(of: BatchResult.self) { group in
            var pending = initialBatches
            var nextBatch = 0
            var inFlight = 0
            var completedWords = 0
            var proposed: [TranscriptCleanupEdit] = []
            var requestCount = 0
            while nextBatch < pending.count || inFlight > 0 {
                try Task.checkCancellation()
                while nextBatch < pending.count && inFlight < max(1, plan.concurrency) {
                    let request = pending[nextBatch]
                    nextBatch += 1
                    inFlight += 1
                    requestCount += 1
                    let requestNumber = requestCount
                    group.addTask {
                        try Task.checkCancellation()
                        await onDiagnostics("Cleanup request \(requestNumber): \(request.range.count) editable words, \(request.contextRange.count) context words")
                        do {
                            let response = try await generate(request)
                            try Task.checkCancellation()
                            let edits = try await parse(response, words, request.range)
                            return .completed(request, edits)
                        } catch TranscriptCleanupError.invalidResponse where request.range.count > plan.minimumRetryWords && request.splitDepth < plan.maximumSplitDepth {
                            // Long responses can be truncated or lose their word references. Retry
                            // smaller ranges instead of discarding a long recording's cleanup.
                            return .split(request)
                        }
                    }
                }
                guard let result = try await group.next() else { break }
                inFlight -= 1
                try Task.checkCancellation()
                switch result {
                case .completed(let request, let edits):
                    proposed += edits
                    completedWords += request.range.count
                    await onProgress(completedWords, words.count)
                case .split(let request):
                    await onDiagnostics("Cleanup response failed validation; retrying two smaller correction ranges (one retry level maximum)")
                    let midpoint = request.range.lowerBound + request.range.count / 2
                    let boundary = segmentBoundary(near: midpoint, after: request.range.lowerBound, words: words)
                    // The input already fit. Split only the editable range so retries
                    // retain the same episode-wide context while returning fewer edits.
                    pending.append(TranscriptCleanupBatch(range: request.range.lowerBound..<boundary,
                                                          contextRange: request.contextRange, splitDepth: request.splitDepth + 1))
                    pending.append(TranscriptCleanupBatch(range: boundary..<request.range.upperBound,
                                                          contextRange: request.contextRange, splitDepth: request.splitDepth + 1))
                }
            }
            try Task.checkCancellation()
            return try TranscriptCleanup.validate(proposed, words: words, allowedRange: words.indices)
        }
    }
}
