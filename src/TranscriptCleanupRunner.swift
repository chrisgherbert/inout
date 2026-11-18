import Foundation
import InOutCore

enum TranscriptCleanupRunner {
    static func suggest(
        source: [TranscriptSegment],
        provider: any SmartMarkerCandidateProvider,
        glossary: String,
        onProgress: @escaping @Sendable (Int, Int) async -> Void,
        onDiagnostics: @escaping @Sendable (String) async -> Void = { _ in },
        onSkippedCorrections: @escaping @Sendable (Int) async -> Void = { _ in }
    ) async throws -> [TranscriptCleanupEdit] {
        let words = TranscriptCleanup.words(in: source)
        let plan: TranscriptCleanupExecutionPlan = provider.id == .appleIntelligence
            ? .local
            : .cloud(tokenLimit: provider.transcriptTokenLimit, glossary: glossary)
        let started = Date()
        let result = try await TranscriptCleanupExecution.suggest(words: words, plan: plan, generate: { request in
            let grouped = Dictionary(grouping: words[request.contextRange], by: \.segmentIndex)
            let entries = grouped.sorted { $0.key < $1.key }.map { segment, words in
                SmartMarkerTranscriptEntry(ordinal: segment, segmentID: source[segment].id,
                    start: words.first!.timing.start, end: words.last!.timing.end,
                    text: words.map(\.timing.word).joined(separator: " "))
            }
            let editableIDs = Set(words[request.range].map(\.segmentIndex)).sorted()
            let instructions = try TranscriptCleanupInstructions.make(editableSegmentIDs: editableIDs, glossary: glossary)
            do {
                return try await provider.generateTranscriptCorrections(
                    entries: entries, instructions: instructions, onDiagnostics: onDiagnostics
                )
            } catch SmartMarkerProviderError.invalidResponse {
                throw TranscriptCleanupError.invalidResponse
            }
        }, parse: { response, words, range in
            let result = try TranscriptCleanupPhrases.resolve(response, words: words, allowedRange: range)
            if result.skipped > 0 {
                await onDiagnostics("Skipped \(result.skipped) correction suggestions with unverified locations, conflicts, or substantially different wording")
                await onSkippedCorrections(result.skipped)
            }
            return result.edits
        }, onProgress: onProgress, onDiagnostics: onDiagnostics)
        await onDiagnostics("Cleanup completed in \(String(format: "%.1f", Date().timeIntervalSince(started)))s with \(result.count) proposed corrections")
        return result
    }
}
