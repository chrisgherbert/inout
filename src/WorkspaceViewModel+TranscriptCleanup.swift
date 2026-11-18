import Foundation
import InOutCore

@MainActor
extension WorkspaceViewModel {
    var transcriptCleanup: TranscriptCleanupSession { sourcePresentation.transcriptCleanup }

    func startTranscriptCleanup(providerID: SmartMarkerProviderID, glossary: String, automaticallyApply: Bool = false) throws {
        guard !isGeneratingTranscript, transcriptHasWordTimings(transcriptSegments),
              transcriptCleanup.phase != .running else { throw TranscriptCleanupError.transcriptChanged }
        let provider = try SmartMarkerProviderFactory.makeProvider(id: providerID, modelIdentifier: nil)
        transcriptCleanupProviderID = providerID
        transcriptCleanupGlossary = glossary
        let source = transcriptSegments
        runTranscriptCleanup(automaticallyApply: automaticallyApply) { callbacks in
            try await TranscriptCleanupRunner.suggest(
                source: source, provider: provider, glossary: glossary,
                onProgress: callbacks.progress, onDiagnostics: callbacks.diagnostics,
                onSkippedCorrections: callbacks.skipped
            )
        }
    }

    func runTranscriptCleanup(
        automaticallyApply: Bool = false,
        operation: @escaping @Sendable (TranscriptCleanupSession.Callbacks) async throws -> [TranscriptCleanupEdit]
    ) {
        transcriptCleanup.start(source: transcriptSegments, sourceID: sourceSessionID,
            diagnostics: { @MainActor [weak self] message in
                self?.appendActivityConsole(message, source: "transcript-cleanup", force: true)
            }, onReady: { [weak self] in
                guard automaticallyApply, let self, !self.transcriptCleanup.edits.isEmpty else { return }
                try self.applyTranscriptCleanup(acceptAll: true)
            }, operation: operation)
    }

    func reviewTranscriptCleanup() {
        selectedTool = .clip
        transcriptCleanup.isReviewing = true
    }

    func startDefaultTranscriptCleanup(automaticallyApply: Bool = false) {
        do {
            try startTranscriptCleanup(providerID: transcriptCleanupProviderID, glossary: transcriptCleanupGlossary,
                                       automaticallyApply: automaticallyApply)
        }
        catch { transcriptCleanup.reportFailure(error) }
    }

    func undoTranscriptCleanup() throws {
        let session = transcriptCleanup
        guard session.phase == .applied, session.sourceID == sourceSessionID,
              TranscriptCleanup.matches(session.snapshot, transcriptSegments) else {
            throw TranscriptCleanupError.transcriptChanged
        }
        let restored = session.undoSnapshot
        transcriptSegments = restored
        transcriptStatusText = "Transcript cleanup undone."
        saveTranscriptToLibrary(restored)
    }

    func applyTranscriptCleanup(acceptAll: Bool = false) throws {
        let session = transcriptCleanup
        guard session.phase == .ready, session.sourceID == sourceSessionID,
              !isGeneratingTranscript, TranscriptCleanup.matches(session.snapshot, transcriptSegments) else {
            throw TranscriptCleanupError.transcriptChanged
        }
        let edits = acceptAll ? session.edits : session.edits.filter { session.selected.contains($0.id) }
        let count = edits.count
        guard count > 0 else { return }
        let before = session.snapshot
        let corrected = try TranscriptCleanup.applying(edits, to: before)
        if originalTranscriptSegments == nil { originalTranscriptSegments = session.snapshot }
        transcriptSegments = corrected
        transcriptStatusText = "Applied \(count) transcript correction\(count == 1 ? "" : "s")."
        saveTranscriptToLibrary(corrected)
        session.didApply(count: count, before: before, after: corrected, sourceID: sourceSessionID)
    }
}
