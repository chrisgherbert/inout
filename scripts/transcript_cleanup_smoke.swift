import Foundation
import Combine
import InOutCore

enum CleanupSmokeError: Error { case failed(String) }

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CleanupSmokeError.failed(message) }
}

@main
struct TranscriptCleanupSmoke {
    static func main() async throws {
        let source = [
            TranscriptSegment(start: 1, end: 3, text: "Hello Tim Millar.", timedWords: [
                TranscriptWordTiming(word: "Hello", start: 1, end: 1.4),
                TranscriptWordTiming(word: "Tim", start: 1.5, end: 1.9),
                TranscriptWordTiming(word: "Millar.", start: 2, end: 3)
            ]),
            TranscriptSegment(start: 4, end: 6, text: "Jadee Vance", timedWords: [
                TranscriptWordTiming(word: "Jadee", start: 4, end: 4.8),
                TranscriptWordTiming(word: "Vance", start: 5, end: 6)
            ])
        ]
        let words = TranscriptCleanup.words(in: source)
        let response = #"{"edits":[{"startWord":2,"endWord":2,"original":"Millar.","replacement":"Miller."},{"startWord":3,"endWord":3,"original":"Jadee","replacement":"J. D."}]}"#
        let edits = try TranscriptCleanup.parse(response, words: words, allowedRange: words.indices)
        let corrected = try TranscriptCleanup.applying(edits, to: source)
        try require(corrected[0].text == "Hello Tim Miller.", "Segment text was not corrected")
        try require(corrected[1].text == "J. D. Vance", "Split spelling correction failed")
        for (before, after) in zip(source, corrected) {
            try require(before.id == after.id && before.start == after.start && before.end == after.end, "Segment anchors changed")
            for (beforeWord, afterWord) in zip(before.timedWords, after.timedWords) {
                try require(beforeWord.start == afterWord.start && beforeWord.end == afterWord.end, "Word timestamps changed")
            }
        }
        let selectedOnly = try TranscriptCleanup.applying([edits[0]], to: source)
        try require(selectedOnly[1].text == source[1].text, "Unselected correction was applied")
        let retimed = [TranscriptSegment(id: source[0].id, start: source[0].start, end: source[0].end,
            text: source[0].text, timedWords: [TranscriptWordTiming(word: "Hello", start: 1.1, end: 1.4)])] + Array(source.dropFirst())
        try require(!TranscriptCleanup.matches(source, retimed), "Changed word timing did not invalidate snapshot")
        try require(!TranscriptCleanup.displayMatches(source, corrected), "Display comparison missed corrected text")
        try require(!TranscriptCleanup.matches(source, corrected), "Text-only changes are not detected")
        try require(TranscriptCleanup.matches(source, source), "Snapshot matching failed")
        let captionText = burnInCaptionSRT(from: makeBurnInCaptionCues(from: corrected, sourceStart: 0, sourceEnd: 7))
        try require(captionText.contains("Miller.") && !captionText.contains("Millar."), "Captions use stale words")
        let merged = try TranscriptCleanup.applying([
            TranscriptCleanupEdit(startWord: 1, endWord: 2, original: "Tim Millar.", replacement: "Tim Miller.")
        ], to: source)
        try require(merged[0].timedWords[1].start == 1.5 && merged[0].timedWords[1].end == 3, "Phrase outer timing changed")
        try require(merged[0].timedWords.count == 2, "Phrase introduced invented word timings")
        try require(TranscriptCleanup.matches(merged.suffix(1).map { $0 }, source.suffix(1).map { $0 }), "Unchanged segment was modified")
        let fenced = try TranscriptCleanup.parse("```json\n{\"edits\":[]}\n```", words: words, allowedRange: words.indices)
        try require(fenced.isEmpty, "Fenced JSON was rejected")
        let invalidEdits = [
            [TranscriptCleanupEdit(startWord: -1, endWord: 0, original: "Hello", replacement: "Hi")],
            [TranscriptCleanupEdit(startWord: 0, endWord: 99, original: "Hello", replacement: "Hi")],
            [TranscriptCleanupEdit(startWord: 2, endWord: 1, original: "Hello", replacement: "Hi")],
            [TranscriptCleanupEdit(startWord: 2, endWord: 3, original: "Millar. Jadee", replacement: "Miller.")],
            [TranscriptCleanupEdit(startWord: 0, endWord: 0, original: "Wrong", replacement: "Hi")],
            [TranscriptCleanupEdit(startWord: 0, endWord: 0, original: "Hello", replacement: "")],
            [TranscriptCleanupEdit(startWord: 0, endWord: 0, original: "Hello", replacement: "Hi\nthere")],
            [edits[0], edits[0]]
        ]
        for invalid in invalidEdits {
            do {
                _ = try TranscriptCleanup.applying(invalid, to: source)
                throw CleanupSmokeError.failed("Invalid edit was accepted")
            } catch TranscriptCleanupError.invalidResponse { }
        }
        do {
            _ = try TranscriptCleanup.parse(response, words: words, allowedRange: 0..<2)
            throw CleanupSmokeError.failed("Out-of-batch correction accepted")
        } catch TranscriptCleanupError.invalidResponse { }
        do {
            _ = try TranscriptCleanup.parse("I cannot do that", words: words, allowedRange: words.indices)
            throw CleanupSmokeError.failed("Non-JSON response accepted")
        } catch TranscriptCleanupError.invalidResponse { }
        try similaritySmoke()
        try phraseSmoke(source: source)
        try await executionSmoke()
        try await verifyBackgroundSession(source: source, edits: edits)
        print("Transcript cleanup smoke passed (including background session lifecycle)")
    }

    static func similaritySmoke() throws {
        for (original, replacement) in [
            ("Cash Patel", "Kash Patel"), ("Tim Millar", "Tim Miller"),
            ("Pete Butta Judge", "Pete Buttigieg"), ("Sochi Toria Small", "Xochitl Torres Small"),
            ("the presence", "the president"), ("G", "Xi"), ("Jadee", "J. D."),
            ("F. B. I.", "FBI"), ("National Public Radio", "NPR"), ("Catherine Rampel", "Catherine Rampell")
        ] {
            try require(TranscriptCleanupSimilarity.allows(original: original, replacement: replacement), "Useful spelling/recognition correction was blocked: \(original)")
        }
        for (original, replacement) in [
            ("Super Majority", "Kill Switch"), ("Searchlight Institute", "Searchlight Strategy Center"),
            ("Adam Hamilton", "Ad Astra"), ("Sochi Toria Small", "Soshe Chandramouli"),
            ("author of Super Majority: How Democrats Can Build Lasting Power", "author of Kill Switch: How Democrats Can Build Lasting Power")
        ] {
            try require(!TranscriptCleanupSimilarity.allows(original: original, replacement: replacement), "Unrelated substitution was accepted: \(original)")
        }
        let source = [TranscriptSegment(start: 0, end: 2, text: "Super Majority", timedWords: [
            TranscriptWordTiming(word: "Super", start: 0, end: 1), TranscriptWordTiming(word: "Majority", start: 1, end: 2)
        ])]
        let words = TranscriptCleanup.words(in: source)
        let resolved = try TranscriptCleanupPhrases.resolve(#"{"edits":[{"segments":[0],"from":"Super Majority","to":"Kill Switch"}]}"#,
            words: words, allowedRange: words.indices)
        try require(resolved.edits.isEmpty && resolved.skipped == 1, "Rejected substitution reached the review list")
    }

    static func phraseSmoke(source: [TranscriptSegment]) throws {
        let words = TranscriptCleanup.words(in: source)
        let response = #"{"edits":[{"segments":[0],"from":"Millar","to":"Miller"},{"segments":[1],"from":"Jadee","to":"J. D."}]}"#
        let edits = try TranscriptCleanupPhrases.parse(response, words: words, allowedRange: words.indices)
        let corrected = try TranscriptCleanup.applying(edits, to: source)
        try require(corrected[0].text == "Hello Tim Miller.", "Phrase cleanup lost punctuation")
        try require(corrected[1].text == "J. D. Vance", "Phrase cleanup lost original timing anchors")
        try require(corrected[0].timedWords[2].start == 2 && corrected[0].timedWords[2].end == 3, "Phrase cleanup shifted timing")
        let repeated = [TranscriptSegment(start: 0, end: 3, text: "Millar, Millar.", timedWords: [
            TranscriptWordTiming(word: "Millar,", start: 0, end: 1), TranscriptWordTiming(word: "Millar.", start: 2, end: 3)
        ])]
        let repeatedWords = TranscriptCleanup.words(in: repeated)
        let replacements = try TranscriptCleanupPhrases.parse(#"{"edits":[{"segments":[0],"from":"Millar","to":"Miller"}]}"#,
            words: repeatedWords, allowedRange: repeatedWords.indices)
        try require(replacements.count == 2, "One compact correction did not resolve repeated occurrences")
        let repeatedResult = try TranscriptCleanup.applying(replacements, to: repeated)
        try require(repeatedResult[0].text == "Miller, Miller.", "Punctuation around repeated names changed")
        for invalid in [
            #"{"edits":[{"segments":[99],"from":"Millar","to":"Miller"}]}"#,
            #"{"edits":[{"segments":[0],"from":"Mill","to":"Miller"}]}"#,
            #"{"edits":[{"segments":[0],"from":"Millar","to":""}]}"#,
            #"{"edits":[{"segments":[0,0],"from":"Millar","to":"Miller"}]}"#,
            #"{"edits":[{"segments":[0],"from":"Absent","to":"Miller"}]}"#,
            #"{"edits":[{"segments":[0],"from":"Millar","to":"Miller"},{"segments":[0],"from":"Tim Millar","to":"Tim Miller"}]}"#
        ] {
            do {
                let result = try TranscriptCleanupPhrases.resolve(invalid, words: words, allowedRange: words.indices)
                try require(result.edits.isEmpty && result.skipped > 0, "Unsafe phrase correction was accepted")
            } catch TranscriptCleanupError.invalidResponse { }
        }
        let partial = try TranscriptCleanupPhrases.resolve(
            #"{"edits":[{"segments":[0,99],"from":"Millar","to":"Miller"}]}"#,
            words: words, allowedRange: words.indices)
        try require(partial.edits.count == 1 && partial.skipped == 1, "Unmatched suggestion discarded a valid correction")
        let unicode = [TranscriptSegment(start: 0, end: 2, text: "“José”", timedWords: [TranscriptWordTiming(word: "“José”", start: 0, end: 2)])]
        let unicodeWords = TranscriptCleanup.words(in: unicode)
        let unicodeEdits = try TranscriptCleanupPhrases.parse(#"{"edits":[{"segments":[0],"from":"José","to":"Jose"}]}"#,
            words: unicodeWords, allowedRange: unicodeWords.indices)
        try require(unicodeEdits[0].replacement == "“Jose”", "Unicode quotation marks were lost")
    }

    static func executionSmoke() async throws {
        let source = (0..<250).map { segment in
            TranscriptSegment(start: Double(segment * 40), end: Double((segment + 1) * 40),
                text: Array(repeating: "word", count: 40).joined(separator: " "),
                timedWords: (0..<40).map { offset in
                    let start = Double(segment * 40 + offset)
                    return TranscriptWordTiming(word: "word", start: start, end: start + 0.8)
                })
        }
        let words = TranscriptCleanup.words(in: source)
        let cloud = TranscriptCleanupExecutionPlan.cloud(tokenLimit: 120_000, glossary: "Tim Miller")
        let whole = TranscriptCleanupExecution.batches(words: words, plan: cloud)
        try require(whole.count == 1 && whole[0].range == words.indices,
                    "A fitting long transcript was needlessly split")
        let singleProbe = CleanupExecutionProbe()
        let wholeEdits = try await TranscriptCleanupExecution.suggest(words: words, plan: cloud, generate: { request in
            await singleProbe.start(request.range)
            await singleProbe.finish()
            return #"{"edits":[]}"#
        })
        let singleStats = await singleProbe.stats()
        try require(singleStats.ranges.count == 1 && wholeEdits.isEmpty, "Full transcript required more than one request")

        let splitPlan = TranscriptCleanupExecutionPlan(maximumInputBytes: 100_000, maximumWords: 1_000,
                                                       concurrency: 3, minimumRetryWords: 300)
        let batches = TranscriptCleanupExecution.batches(words: words, plan: splitPlan)
        try require(batches.flatMap { Array($0.range) } == Array(words.indices), "Batch coverage has gaps or duplicates")
        for request in batches {
            try require(request.range.count <= 1_000, "Batch exceeded the word budget")
            if request.range.upperBound < words.count {
                let end = request.range.upperBound
                try require(words[end - 1].segmentIndex != words[end].segmentIndex, "Batch needlessly split a segment")
            }
        }
        let byteLimitedPlan = TranscriptCleanupExecutionPlan(maximumInputBytes: 5_000, maximumWords: nil,
                                                             concurrency: 3, minimumRetryWords: 300)
        let byteBatches = TranscriptCleanupExecution.batches(words: words, plan: byteLimitedPlan)
        try require(byteBatches.count > 1, "Oversized input was sent as one request")
        try require(byteBatches.flatMap { Array($0.range) } == Array(words.indices), "Size budget dropped words")
        for request in byteBatches {
            let bytes = request.range.reduce(0) { $0 + words[$1].timing.word.utf8.count + String($1).count + 4 }
            try require(bytes <= byteLimitedPlan.maximumInputBytes, "Input exceeded its byte budget")
        }
        let localBatches = TranscriptCleanupExecution.batches(words: words, plan: .local)
        try require(localBatches.allSatisfy { $0.range.count <= 60 }, "Local model exceeded its word budget")
        let parallelProbe = CleanupExecutionProbe()
        let parallelEdits = try await TranscriptCleanupExecution.suggest(words: words, plan: splitPlan, generate: { request in
            await parallelProbe.start(request.range)
            try await Task.sleep(nanoseconds: UInt64((request.range.lowerBound == 0 ? 15 : 5) * 1_000_000))
            await parallelProbe.finish()
            let index = request.range.lowerBound
            return "{\"edits\":[{\"startWord\":\(index),\"endWord\":\(index),\"original\":\"word\",\"replacement\":\"Word\"}]}"
        }, onProgress: { completed, _ in await parallelProbe.progress(completed) })
        let parallelStats = await parallelProbe.stats()
        try require(parallelStats.maximumActive == 3, "Oversized transcript requests were serial or unbounded")
        try require(parallelStats.progress.last == words.count, "Progress did not complete")
        try require(parallelStats.progress == parallelStats.progress.sorted(), "Progress went backwards")
        try require(parallelEdits.map(\.startWord) == batches.map { $0.range.lowerBound }, "Out-of-order results lost their anchors")
        let corrected = try TranscriptCleanup.applying(parallelEdits, to: source)
        for (before, after) in zip(source, corrected) {
            try require(before.start == after.start && before.end == after.end, "Parallel cleanup changed segment timing")
            for (a, b) in zip(before.timedWords, after.timedWords) {
                try require(a.start == b.start && a.end == b.end, "Parallel cleanup changed word timing")
            }
        }

        let retryProbe = CleanupExecutionProbe()
        _ = try await TranscriptCleanupExecution.suggest(words: words, plan: cloud, generate: { request in
            await retryProbe.start(request.range)
            await retryProbe.finish()
            if request.range == words.indices { return "truncated output" }
            try require(request.contextRange == words.indices, "Output fallback lost full-transcript context")
            return #"{"edits":[]}"#
        }, onProgress: { completed, _ in await retryProbe.progress(completed) })
        let retryStats = await retryProbe.stats()
        try require(retryStats.ranges.count == 3, "Invalid full response did not retry exactly two smaller sections")
        try require(retryStats.ranges.dropFirst().flatMap { Array($0) }.sorted() == Array(words.indices), "Retry ranges changed coverage")
        try require(retryStats.progress.last == words.count, "Retried words were lost or double-counted")

        do {
            _ = try await TranscriptCleanupExecution.suggest(words: Array(words.prefix(40)), plan: cloud, generate: { _ in "invalid" })
            throw CleanupSmokeError.failed("Permanently invalid response was accepted")
        } catch TranscriptCleanupError.invalidResponse { }

        let failureProbe = CleanupExecutionProbe()
        do {
            _ = try await TranscriptCleanupExecution.suggest(words: words, plan: cloud, generate: { request in
                await failureProbe.start(request.range)
                return "invalid"
            })
            throw CleanupSmokeError.failed("Invalid retry returned results")
        } catch TranscriptCleanupError.invalidResponse { }
        let failureStats = await failureProbe.stats()
        try require(failureStats.ranges.count <= 3, "Invalid output recursively triggered too many full-context requests")

        let cancelProbe = CleanupExecutionProbe()
        let task = Task {
            try await TranscriptCleanupExecution.suggest(words: words, plan: splitPlan, generate: { request in
                await cancelProbe.start(request.range)
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return #"{"edits":[]}"#
            }, onProgress: { completed, _ in await cancelProbe.progress(completed) })
        }
        for _ in 0..<100 {
            if await cancelProbe.stats().ranges.count == 3 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        do {
            _ = try await task.value
            throw CleanupSmokeError.failed("Cancelled cleanup returned results")
        } catch is CancellationError { }
        let cancelStats = await cancelProbe.stats()
        try require(cancelStats.ranges.count == 3, "Cancellation started extra queued requests")
        try require(cancelStats.progress == [0], "Cancelled requests reported completed work")
        print("Cleanup execution passed (10,000 words: one full-context request; bounded parallel fallback, retry, cancellation)")
    }

}


private actor CleanupExecutionProbe {
    private var ranges: [Range<Int>] = []
    private var active = 0
    private var maximumActive = 0
    private var completed: [Int] = []

    func start(_ range: Range<Int>) {
        ranges.append(range)
        active += 1
        maximumActive = max(maximumActive, active)
    }
    func finish() { active -= 1 }
    func progress(_ count: Int) { completed.append(count) }
    func stats() -> (ranges: [Range<Int>], maximumActive: Int, progress: [Int]) {
        (ranges, maximumActive, completed)
    }
}

private actor CleanupSessionGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { opened = true; continuation?.resume(); continuation = nil }
}

@MainActor
private func verifyBackgroundSession(source: [TranscriptSegment], edits: [TranscriptCleanupEdit]) async throws {
    let session = TranscriptCleanupSession()
    let sourceID = UUID()
    try require(session.canStartNewCleanup, "Idle cleanup cannot use Quick Clean Up")
    var idleNotifications = 0
    let observer = session.objectWillChange.sink { idleNotifications += 1 }
    session.reset()
    try require(idleNotifications == 0, "Resetting inactive cleanup published UI changes during ordinary transcript updates")
    withExtendedLifetime(observer) {}
    func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw CleanupSmokeError.failed("Background session did not reach expected state")
    }
    let gate = CleanupSessionGate()
    var completions = 0
    session.start(source: source, sourceID: sourceID, onReady: { completions += 1 }) { callbacks in
        await callbacks.progress(0, 5)
        await callbacks.progress(2, 5)
        await gate.wait()
        await callbacks.skipped(1)
        return edits
    }
    try require(session.phase == .running, "Cleanup did not start without a sheet")
    try require(!session.canStartNewCleanup, "Quick Clean Up can replace a running request")
    try await waitFor { session.completedWords == 2 }
    try require(session.progressFraction == 0.4, "Cleanup progress did not reflect completed words")
    await gate.release()
    try await waitFor { session.phase == .ready }
    try require(completions == 1, "Cleanup completion did not run exactly once")
    try require(!session.canStartNewCleanup, "Quick Clean Up can overwrite pending corrections")
    try require(session.selected == Set(edits.map(\.id)), "Review selection was not retained")
    try require(session.snapshot[0].text == source[0].text, "Cleanup applied edits without review")
    try require(session.skippedSuggestions == 1, "Skipped suggestions were lost")
    session.selected.remove(edits[0].id)
    try require(session.selected.count == edits.count - 1, "Review selection could not be edited")

    let cancelledGate = CleanupSessionGate()
    let oldFinished = CleanupSessionGate()
    var cancelledCompletionRan = false
    session.start(source: source, sourceID: sourceID, onReady: { cancelledCompletionRan = true }) { callbacks in
        await cancelledGate.wait() // Deliberately simulate a provider ignoring cancellation.
        await callbacks.progress(999, 999)
        await callbacks.skipped(999)
        await oldFinished.release()
        return edits
    }
    // Allow the old operation to start before cancelling it.
    try await Task.sleep(nanoseconds: 5_000_000)
    session.reset()
    try require(session.phase == .idle && session.snapshot.isEmpty, "Cancel retained stale review state")
    session.start(source: source, sourceID: UUID()) { _ in [] }
    try await waitFor { session.phase == .ready }
    await cancelledGate.release()
    await oldFinished.wait()
    try await Task.sleep(nanoseconds: 5_000_000)
    try require(session.phase == .ready && session.edits.isEmpty && session.skippedSuggestions == 0,
                "Cancelled request overwrote the newer result")
    try require(!session.progress.contains("999"), "Cancelled request overwrote current progress")
    try require(!cancelledCompletionRan, "Cancelled cleanup invoked automatic application")
    try require(session.canStartNewCleanup, "A no-change result cannot start another cleanup")

    session.start(source: source, sourceID: sourceID) { _ in throw CleanupSmokeError.failed("test failure") }
    try await waitFor { session.phase == .failed }
    try require(session.errorText != nil, "Background failure was not available for retry")
    session.start(source: source, sourceID: sourceID) { _ in edits }
    try await waitFor { session.phase == .ready }
    try require(session.errorText == nil, "Retry retained the previous error")
    session.reset()
    try require(session.phase == .idle && session.selected.isEmpty, "Discard did not clear review state")
}
