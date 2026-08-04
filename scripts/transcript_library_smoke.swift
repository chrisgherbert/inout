import Foundation
import InOutCore
import SQLite3

enum SmokeFailure: Error {
    case failed(String)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SmokeFailure.failed(message) }
}

private func ageHistory(at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw SmokeFailure.failed("Could not open smoke database for retention test")
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, "UPDATE transcripts SET last_accessed_at = 0;", nil, nil, nil) == SQLITE_OK else {
        throw SmokeFailure.failed("Could not age transcript history")
    }
}

@main
struct TranscriptLibrarySmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeFailure.failed("Expected a temporary test directory")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("library.sqlite")
        let library = try TranscriptLibrary(databaseURL: databaseURL)
        let originalURL = root.appendingPathComponent("original-media.bin")
        let movedURL = root.appendingPathComponent("moved-media.bin")
        let originalData = Data((0..<(256 * 1_024)).map { UInt8($0 % 251) })
        try originalData.write(to: originalURL)

        let segments = [
            TranscriptSegment(
                start: 0,
                end: 1.25,
                text: "Hello world.",
                timedWords: [
                    TranscriptWordTiming(word: "Hello", start: 0, end: 0.5),
                    TranscriptWordTiming(word: "world.", start: 0.6, end: 1.25)
                ]
            ),
            TranscriptSegment(start: 1.5, end: 2.25, text: "Second segment.")
        ]

        try await library.save(
            mediaURL: originalURL,
            duration: 2.25,
            segments: segments,
            modelIdentifier: "smoke-model",
            retention: .ninetyDays
        )
        var snapshot = try await library.snapshot(retention: .ninetyDays, limit: 100)
        try require(snapshot.entries.count == 1, "Saved transcript is missing from history")
        try require(snapshot.storageBytes > 0, "Stored transcript payload has no size")

        guard let restored = try await library.transcript(for: originalURL, retention: .ninetyDays) else {
            throw SmokeFailure.failed("Saved transcript did not restore")
        }
        try require(restored.segments.count == 2, "Segment count changed during restore")
        try require(restored.segments[0].timedWords.count == 2, "Word timing was not preserved")
        try require(restored.segments[0].timedWords[1].word == "world.", "Word text changed during restore")

        try await library.setPinned(true, id: restored.entry.id)
        try FileManager.default.moveItem(at: originalURL, to: movedURL)
        guard let movedRestore = try await library.transcript(for: movedURL, retention: .ninetyDays) else {
            throw SmokeFailure.failed("A moved but unchanged file did not match")
        }
        try require(movedRestore.entry.lastPath == movedURL.path, "Moved path was not recorded")
        snapshot = try await library.snapshot(retention: .ninetyDays, limit: 100)
        try require(snapshot.entries[0].isPinned, "Pinned state was not preserved")

        var changedData = originalData
        changedData[128 * 1_024] ^= 0xff
        try changedData.write(to: movedURL)
        let changedRestore = try await library.transcript(for: movedURL, retention: .ninetyDays)
        try require(changedRestore == nil, "Modified media incorrectly reused a transcript")
        do {
            try await library.relocate(id: restored.entry.id, to: movedURL)
            throw SmokeFailure.failed("Relocation accepted mismatched media")
        } catch TranscriptLibraryError.mismatchedMedia {
            // Expected.
        }

        try originalData.write(to: movedURL)
        try await library.relocate(id: restored.entry.id, to: movedURL)
        try ageHistory(at: databaseURL)
        snapshot = try await library.snapshot(retention: .thirtyDays, limit: 100)
        try require(snapshot.entries.count == 1, "Retention removed a pinned transcript")
        try await library.setPinned(false, id: restored.entry.id)
        snapshot = try await library.snapshot(retention: .thirtyDays, limit: 100)
        try require(snapshot.entries.isEmpty, "Expired unpinned transcript was not removed")

        try await library.remove(id: restored.entry.id)
        snapshot = try await library.snapshot(retention: .ninetyDays, limit: 100)
        try require(snapshot.entries.isEmpty, "Removed transcript remains in history")

        for index in 0..<52 {
            let mediaURL = root.appendingPathComponent("media-\(index).bin")
            try Data(repeating: UInt8(index), count: 192 * 1_024).write(to: mediaURL)
            try await library.save(
                mediaURL: mediaURL,
                duration: Double(index + 1),
                segments: segments,
                modelIdentifier: "smoke-model",
                retention: .untilRemoved
            )
        }
        snapshot = try await library.snapshot(retention: .untilRemoved, limit: 100)
        try require(snapshot.entries.count == 50, "Unpinned history was not capped at 50 entries")

        try await library.removeAll()
        snapshot = try await library.snapshot(retention: .untilRemoved, limit: 100)
        try require(snapshot.entries.isEmpty, "Clear history did not remove all transcripts")
        print("Transcript library smoke test passed.")
    }
}
