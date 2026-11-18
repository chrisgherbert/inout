import Foundation
import Combine
import InOutCore

/// A window's cleanup request and review results outlive the setup/review sheet.
@MainActor
final class TranscriptCleanupSession: ObservableObject {
    enum Phase { case idle, running, ready, failed, applied }
    struct Callbacks: Sendable {
        let progress: @Sendable (Int, Int) async -> Void
        let diagnostics: @Sendable (String) async -> Void
        let skipped: @Sendable (Int) async -> Void
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = ""
    @Published private(set) var errorText: String?
    @Published private(set) var edits: [TranscriptCleanupEdit] = []
    @Published private(set) var skippedSuggestions = 0
    @Published var selected: Set<Int> = []
    @Published var isReviewing = false
    @Published private(set) var completedWords = 0
    @Published private(set) var totalWords = 0
    private(set) var appliedCount = 0
    private(set) var undoSnapshot: [TranscriptSegment] = []

    var canStartNewCleanup: Bool {
        phase != .running && (phase != .ready || edits.isEmpty)
    }

    var progressFraction: Double? {
        guard totalWords > 0, completedWords > 0 else { return nil }
        return min(1, Double(completedWords) / Double(totalWords))
    }

    func reportFailure(_ error: Error) {
        reset()
        errorText = error.localizedDescription
        phase = .failed
    }

    func didApply(count: Int, before: [TranscriptSegment], after: [TranscriptSegment], sourceID: UUID) {
        appliedCount = count
        undoSnapshot = before
        snapshot = after
        self.sourceID = sourceID
        phase = .applied
    }

    private(set) var snapshot: [TranscriptSegment] = []
    private(set) var words: [TranscriptCleanupWord] = []
    private(set) var sourceID: UUID?
    private(set) var startedAt = Date()
    private var requestID = UUID()
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    func reset() {
        // Ordinary transcription publishes segments repeatedly. An unused cleanup
        // session must not wake its sidebar, footer, or review subscribers each time.
        guard phase != .idle || task != nil || isReviewing || !snapshot.isEmpty else { return }
        requestID = UUID()
        task?.cancel()
        task = nil
        isReviewing = false
        completedWords = 0
        totalWords = 0
        appliedCount = 0
        undoSnapshot = []
        snapshot = []
        words = []
        sourceID = nil
        edits = []
        selected = []
        skippedSuggestions = 0
        errorText = nil
        progress = ""
        phase = .idle
    }

    func start(
        source: [TranscriptSegment], sourceID: UUID,
        diagnostics: @escaping @Sendable (String) async -> Void = { _ in },
        onReady: @escaping @MainActor () throws -> Void = {},
        operation: @escaping @Sendable (Callbacks) async throws -> [TranscriptCleanupEdit]
    ) {
        reset()
        snapshot = source
        words = TranscriptCleanup.words(in: source)
        totalWords = words.count
        self.sourceID = sourceID
        startedAt = Date()
        progress = "Reviewing transcript…"
        phase = .running
        let id = requestID
        let callbacks = Callbacks(progress: { @MainActor [weak self] completed, total in
            guard let self, self.requestID == id else { return }
            self.completedWords = max(0, completed)
            self.totalWords = max(0, total)
            self.progress = completed == 0 ? "Reviewing transcript…"
                : "Reviewed \(completed.formatted()) of \(total.formatted()) words…"
        }, diagnostics: { @MainActor [weak self] message in
            guard let self, self.requestID == id else { return }
            await diagnostics(message)
            guard self.requestID == id else { return }
            if message.contains("retrying") { self.progress = "Retrying a smaller correction response…" }
        }, skipped: { @MainActor [weak self] count in
            guard let self, self.requestID == id else { return }
            self.skippedSuggestions += count
        })
        task = Task { [weak self] in
            do {
                let proposed = try await operation(callbacks)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.edits = proposed
                self.selected = Set(proposed.map(\.id))
                self.phase = .ready
                self.task = nil
                // Clear the task before applying: applying updates the transcript,
                // which resets the session and must not cancel its own completion.
                try onReady()
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.errorText = error.localizedDescription
                self.phase = .failed
                self.task = nil
                await diagnostics("Cleanup failed: \(error.localizedDescription)")
            }
        }
    }
}
