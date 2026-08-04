import AppKit
import Foundation
import InOutCore

@MainActor
extension WorkspaceViewModel {
    func refreshTranscriptHistory() {
        let retention = transcriptRetentionPolicy
        Task { [weak self] in
            do {
                let snapshot = try await TranscriptLibrary.shared.snapshot(retention: retention)
                guard let self else { return }
                transcriptHistoryEntries = snapshot.entries
                transcriptHistoryStorageBytes = snapshot.storageBytes
            } catch {
                self?.appendActivityConsole("Transcript history refresh failed: \(error.localizedDescription)", source: "transcript-library")
            }
        }
    }

    func restoreTranscriptFromLibrary(for url: URL, sourceSessionID expectedSessionID: UUID) {
        transcriptLibraryRestoreTask?.cancel()
        isCheckingTranscriptLibrary = true
        transcriptStatusText = "Checking for a saved transcript…"
        let retention = transcriptRetentionPolicy
        transcriptLibraryRestoreTask = Task { [weak self] in
            defer {
                if self?.sourceSessionID == expectedSessionID {
                    self?.isCheckingTranscriptLibrary = false
                }
            }
            do {
                let stored = try await TranscriptLibrary.shared.transcript(for: url, retention: retention)
                guard !Task.isCancelled,
                      let self,
                      sourceSessionID == expectedSessionID,
                      sourceURL?.path == url.path else { return }
                guard let stored else {
                    transcriptStatusText = "No transcript generated yet."
                    return
                }
                transcriptSegments = stored.segments
                hasCachedTranscript = true
                let count = stored.segments.count
                transcriptStatusText = count == 0
                    ? "Loaded saved transcript (no speech detected)."
                    : "Loaded saved transcript (\(count) segment(s))."
                analyzeStatusText = transcriptStatusText
                uiMessage = "Loaded saved transcript for \(url.lastPathComponent)"
                refreshTranscriptHistory()
            } catch {
                guard !Task.isCancelled else { return }
                if self?.sourceSessionID == expectedSessionID {
                    self?.transcriptStatusText = "No transcript generated yet."
                }
                self?.appendActivityConsole("Saved transcript lookup failed: \(error.localizedDescription)", source: "transcript-library")
            }
        }
    }

    func saveTranscriptToLibrary(_ transcript: [TranscriptSegment]) {
        guard let url = sourceURL else { return }
        let expectedSessionID = sourceSessionID
        let duration = sourceDurationSeconds
        let retention = transcriptRetentionPolicy
        transcriptLibrarySaveTask?.cancel()
        transcriptLibrarySaveTask = Task { [weak self] in
            do {
                try await TranscriptLibrary.shared.save(
                    mediaURL: url,
                    duration: duration,
                    segments: transcript,
                    modelIdentifier: "parakeet-tdt-0.6b-v2",
                    retention: retention
                )
                guard !Task.isCancelled, let self else { return }
                if sourceSessionID == expectedSessionID {
                    appendActivityConsole("Transcript saved to local history", source: "transcript-library")
                }
                refreshTranscriptHistory()
            } catch {
                guard !Task.isCancelled else { return }
                self?.appendActivityConsole("Transcript history save failed: \(error.localizedDescription)", source: "transcript-library")
            }
        }
    }

    func openTranscriptHistoryEntry(_ entry: TranscriptLibraryEntry) {
        guard entry.fileIsAvailable else {
            locateTranscriptHistoryEntry(entry)
            return
        }
        setSource(URL(fileURLWithPath: entry.lastPath))
    }

    func showTranscriptHistoryEntryInFinder(_ entry: TranscriptLibraryEntry) {
        guard entry.fileIsAvailable else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.lastPath)])
    }

    func setTranscriptHistoryEntryPinned(_ entry: TranscriptLibraryEntry, pinned: Bool) {
        Task { [weak self] in
            do {
                try await TranscriptLibrary.shared.setPinned(pinned, id: entry.id)
                self?.refreshTranscriptHistory()
            } catch {
                self?.uiMessage = error.localizedDescription
            }
        }
    }

    func removeTranscriptHistoryEntry(_ entry: TranscriptLibraryEntry) {
        Task { [weak self] in
            do {
                try await TranscriptLibrary.shared.remove(id: entry.id)
                self?.refreshTranscriptHistory()
            } catch {
                self?.uiMessage = error.localizedDescription
            }
        }
    }

    func clearTranscriptHistory() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear Transcript History?"
        alert.informativeText = "This removes all locally saved transcripts. Original media files are not affected."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { [weak self] in
            do {
                try await TranscriptLibrary.shared.removeAll()
                self?.refreshTranscriptHistory()
                self?.uiMessage = "Transcript history cleared."
            } catch {
                self?.uiMessage = error.localizedDescription
            }
        }
    }

    func locateTranscriptHistoryEntry(_ entry: TranscriptLibraryEntry) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Locate \(entry.fileName)"
        panel.prompt = "Locate"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { [weak self] in
            do {
                try await TranscriptLibrary.shared.relocate(id: entry.id, to: url)
                self?.refreshTranscriptHistory()
                self?.setSource(url)
            } catch {
                self?.uiMessage = error.localizedDescription
            }
        }
    }
}
