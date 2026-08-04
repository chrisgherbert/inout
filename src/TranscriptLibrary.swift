import CryptoKit
import Foundation
import InOutCore
import SQLite3

enum TranscriptRetentionPolicy: String, CaseIterable, Identifiable {
    case thirtyDays
    case ninetyDays
    case untilRemoved

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thirtyDays: return "30 Days"
        case .ninetyDays: return "90 Days"
        case .untilRemoved: return "No Time Limit"
        }
    }

    var maximumAge: TimeInterval? {
        switch self {
        case .thirtyDays: return 30 * 24 * 60 * 60
        case .ninetyDays: return 90 * 24 * 60 * 60
        case .untilRemoved: return nil
        }
    }
}

struct TranscriptLibraryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let fileName: String
    let lastPath: String
    let duration: Double
    let segmentCount: Int
    let createdAt: Date
    let lastAccessedAt: Date
    let isPinned: Bool
    let fileIsAvailable: Bool
}

struct StoredTranscript: Sendable {
    let entry: TranscriptLibraryEntry
    let segments: [TranscriptSegment]
}

struct TranscriptLibrarySnapshot: Sendable {
    let entries: [TranscriptLibraryEntry]
    let storageBytes: Int64
}

enum TranscriptLibraryError: LocalizedError {
    case database(String)
    case unreadableMedia
    case mismatchedMedia

    var errorDescription: String? {
        switch self {
        case .database(let message): return "Transcript library error: \(message)"
        case .unreadableMedia: return "The media file could not be read."
        case .mismatchedMedia: return "The selected file does not match this transcript."
        }
    }
}

private struct StoredTranscriptPayload: Codable {
    let schemaVersion: Int
    let segments: [StoredTranscriptSegment]
}

private struct StoredTranscriptSegment: Codable {
    let id: UUID
    let start: Double
    let end: Double
    let text: String
    let timedWords: [StoredTranscriptWord]

    init(_ segment: TranscriptSegment) {
        id = segment.id
        start = segment.start
        end = segment.end
        text = segment.text
        timedWords = segment.timedWords.map(StoredTranscriptWord.init)
    }

    var transcriptSegment: TranscriptSegment {
        TranscriptSegment(
            id: id,
            start: start,
            end: end,
            text: text,
            timedWords: timedWords.map(\.transcriptWord)
        )
    }
}

private struct StoredTranscriptWord: Codable {
    let word: String
    let start: Double
    let end: Double

    init(_ timing: TranscriptWordTiming) {
        word = timing.word
        start = timing.start
        end = timing.end
    }

    var transcriptWord: TranscriptWordTiming {
        TranscriptWordTiming(word: word, start: start, end: end)
    }
}

actor TranscriptLibrary {
    static let shared: TranscriptLibrary = {
        do {
            return try TranscriptLibrary(databaseURL: defaultDatabaseURL())
        } catch {
            // A damaged cache must not prevent the app from opening. Use a disposable
            // database for this process so the rest of the app remains available.
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("In-Out-Transcript-Library-\(UUID().uuidString).sqlite")
            do {
                return try TranscriptLibrary(databaseURL: fallback)
            } catch {
                preconditionFailure("Unable to initialize transcript library: \(error.localizedDescription)")
            }
        }
    }()

    private static let payloadSchemaVersion = 1
    private static let maximumUnpinnedEntries = 50
    private static let maximumStorageBytes: Int64 = 500 * 1_024 * 1_024
    private static let sampleSize = 64 * 1_024
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let databaseURL: URL
    private var database: OpaquePointer?

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let handle { sqlite3_close(handle) }
            throw TranscriptLibraryError.database(message)
        }
        database = handle

        try Self.execute(on: handle, sql: "PRAGMA journal_mode=WAL;")
        try Self.execute(on: handle, sql: "PRAGMA foreign_keys=ON;")
        try Self.execute(
            on: handle,
            sql:
            """
            CREATE TABLE IF NOT EXISTS transcripts (
                fingerprint TEXT PRIMARY KEY,
                file_name TEXT NOT NULL,
                last_path TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                modification_date REAL NOT NULL,
                media_duration REAL NOT NULL,
                created_at REAL NOT NULL,
                last_accessed_at REAL NOT NULL,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                model_identifier TEXT NOT NULL,
                segment_count INTEGER NOT NULL,
                payload BLOB NOT NULL
            );
            """
        )
        try Self.execute(on: handle, sql: "CREATE INDEX IF NOT EXISTS transcripts_last_accessed ON transcripts(last_accessed_at DESC);")
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func transcript(for mediaURL: URL, retention: TranscriptRetentionPolicy) throws -> StoredTranscript? {
        try prune(retention: retention)
        let identity = try mediaIdentity(for: mediaURL)
        let sql = """
            SELECT file_name, last_path, media_duration, segment_count, created_at,
                   last_accessed_at, is_pinned, payload
            FROM transcripts WHERE fingerprint = ? LIMIT 1;
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(identity.fingerprint, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        guard let payloadData = blob(at: 7, in: statement) else {
            throw TranscriptLibraryError.database("Stored transcript payload is missing")
        }
        let payload = try JSONDecoder().decode(StoredTranscriptPayload.self, from: payloadData)
        guard payload.schemaVersion == Self.payloadSchemaVersion else { return nil }

        let now = Date().timeIntervalSince1970
        try updateSourceLocation(
            fingerprint: identity.fingerprint,
            fileName: mediaURL.lastPathComponent,
            path: mediaURL.path,
            fileSize: identity.fileSize,
            modificationDate: identity.modificationDate,
            lastAccessedAt: now
        )

        let entry = TranscriptLibraryEntry(
            id: identity.fingerprint,
            fileName: mediaURL.lastPathComponent,
            lastPath: mediaURL.path,
            duration: sqlite3_column_double(statement, 2),
            segmentCount: Int(sqlite3_column_int64(statement, 3)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            lastAccessedAt: Date(timeIntervalSince1970: now),
            isPinned: sqlite3_column_int(statement, 6) != 0,
            fileIsAvailable: true
        )
        return StoredTranscript(entry: entry, segments: payload.segments.map(\.transcriptSegment))
    }

    func save(
        mediaURL: URL,
        duration: Double,
        segments: [TranscriptSegment],
        modelIdentifier: String,
        retention: TranscriptRetentionPolicy
    ) throws {
        let identity = try mediaIdentity(for: mediaURL)
        let payload = StoredTranscriptPayload(
            schemaVersion: Self.payloadSchemaVersion,
            segments: segments.map(StoredTranscriptSegment.init)
        )
        let payloadData = try JSONEncoder().encode(payload)
        let now = Date().timeIntervalSince1970
        let sql = """
            INSERT INTO transcripts (
                fingerprint, file_name, last_path, file_size, modification_date,
                media_duration, created_at, last_accessed_at, is_pinned,
                model_identifier, segment_count, payload
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
            ON CONFLICT(fingerprint) DO UPDATE SET
                file_name = excluded.file_name,
                last_path = excluded.last_path,
                file_size = excluded.file_size,
                modification_date = excluded.modification_date,
                media_duration = excluded.media_duration,
                last_accessed_at = excluded.last_accessed_at,
                model_identifier = excluded.model_identifier,
                segment_count = excluded.segment_count,
                payload = excluded.payload;
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(identity.fingerprint, at: 1, in: statement)
        bind(mediaURL.lastPathComponent, at: 2, in: statement)
        bind(mediaURL.path, at: 3, in: statement)
        sqlite3_bind_int64(statement, 4, identity.fileSize)
        sqlite3_bind_double(statement, 5, identity.modificationDate)
        sqlite3_bind_double(statement, 6, duration)
        sqlite3_bind_double(statement, 7, now)
        sqlite3_bind_double(statement, 8, now)
        bind(modelIdentifier, at: 9, in: statement)
        sqlite3_bind_int64(statement, 10, Int64(segments.count))
        _ = payloadData.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 11, bytes.baseAddress, Int32(bytes.count), Self.sqliteTransient)
        }
        try stepDone(statement)
        try prune(retention: retention)
    }

    func snapshot(retention: TranscriptRetentionPolicy, limit: Int = 12) throws -> TranscriptLibrarySnapshot {
        try prune(retention: retention)
        let statement = try prepare(
            """
            SELECT fingerprint, file_name, last_path, media_duration, segment_count,
                   created_at, last_accessed_at, is_pinned
            FROM transcripts
            ORDER BY is_pinned DESC, last_accessed_at DESC
            LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
        var entries: [TranscriptLibraryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = text(at: 2, in: statement)
            entries.append(
                TranscriptLibraryEntry(
                    id: text(at: 0, in: statement),
                    fileName: text(at: 1, in: statement),
                    lastPath: path,
                    duration: sqlite3_column_double(statement, 3),
                    segmentCount: Int(sqlite3_column_int64(statement, 4)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    lastAccessedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                    isPinned: sqlite3_column_int(statement, 7) != 0,
                    fileIsAvailable: FileManager.default.fileExists(atPath: path)
                )
            )
        }
        return TranscriptLibrarySnapshot(entries: entries, storageBytes: try storageBytes())
    }

    func setPinned(_ pinned: Bool, id: String) throws {
        let statement = try prepare("UPDATE transcripts SET is_pinned = ? WHERE fingerprint = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, pinned ? 1 : 0)
        bind(id, at: 2, in: statement)
        try stepDone(statement)
    }

    func remove(id: String) throws {
        let statement = try prepare("DELETE FROM transcripts WHERE fingerprint = ?;")
        defer { sqlite3_finalize(statement) }
        bind(id, at: 1, in: statement)
        try stepDone(statement)
    }

    func removeAll() throws {
        try execute("DELETE FROM transcripts;")
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    func relocate(id: String, to mediaURL: URL) throws {
        let identity = try mediaIdentity(for: mediaURL)
        guard identity.fingerprint == id else { throw TranscriptLibraryError.mismatchedMedia }
        try updateSourceLocation(
            fingerprint: id,
            fileName: mediaURL.lastPathComponent,
            path: mediaURL.path,
            fileSize: identity.fileSize,
            modificationDate: identity.modificationDate,
            lastAccessedAt: Date().timeIntervalSince1970
        )
    }

    private struct MediaIdentity {
        let fingerprint: String
        let fileSize: Int64
        let modificationDate: Double
    }

    private func mediaIdentity(for url: URL) throws -> MediaIdentity {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSizeValue = values.fileSize else {
            throw TranscriptLibraryError.unreadableMedia
        }
        let fileSize = Int64(fileSizeValue)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var sampledData = Data("In-Out transcript fingerprint v1\0\(fileSize)\0".utf8)
        let sampleLength = min(Int64(Self.sampleSize), fileSize)
        let offsets = Set([
            Int64(0),
            max(0, (fileSize - sampleLength) / 2),
            max(0, fileSize - sampleLength)
        ]).sorted()
        for offset in offsets {
            try handle.seek(toOffset: UInt64(offset))
            if let data = try handle.read(upToCount: Int(sampleLength)) {
                sampledData.append(contentsOf: withUnsafeBytes(of: offset.bigEndian, Array.init))
                sampledData.append(data)
            }
        }
        let digest = SHA256.hash(data: sampledData).map { String(format: "%02x", $0) }.joined()
        return MediaIdentity(
            fingerprint: digest,
            fileSize: fileSize,
            modificationDate: values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
    }

    private func prune(retention: TranscriptRetentionPolicy) throws {
        if let maximumAge = retention.maximumAge {
            let cutoff = Date().addingTimeInterval(-maximumAge).timeIntervalSince1970
            let statement = try prepare("DELETE FROM transcripts WHERE is_pinned = 0 AND last_accessed_at < ?;")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, cutoff)
            try stepDone(statement)
        }

        let countStatement = try prepare("SELECT COUNT(*) FROM transcripts WHERE is_pinned = 0;")
        defer { sqlite3_finalize(countStatement) }
        guard sqlite3_step(countStatement) == SQLITE_ROW else { return }
        let unpinnedCount = Int(sqlite3_column_int64(countStatement, 0))
        if unpinnedCount > Self.maximumUnpinnedEntries {
            let excess = unpinnedCount - Self.maximumUnpinnedEntries
            let statement = try prepare(
                """
                DELETE FROM transcripts WHERE fingerprint IN (
                    SELECT fingerprint FROM transcripts WHERE is_pinned = 0
                    ORDER BY last_accessed_at ASC LIMIT ?
                );
                """
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(excess))
            try stepDone(statement)
        }

        while try storageBytes() > Self.maximumStorageBytes {
            let statement = try prepare(
                """
                DELETE FROM transcripts WHERE fingerprint = (
                    SELECT fingerprint FROM transcripts WHERE is_pinned = 0
                    ORDER BY last_accessed_at ASC LIMIT 1
                );
                """
            )
            defer { sqlite3_finalize(statement) }
            try stepDone(statement)
            guard sqlite3_changes(database) > 0 else { break }
        }
    }

    private func storageBytes() throws -> Int64 {
        let statement = try prepare("SELECT COALESCE(SUM(length(payload)), 0) FROM transcripts;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func updateSourceLocation(
        fingerprint: String,
        fileName: String,
        path: String,
        fileSize: Int64,
        modificationDate: Double,
        lastAccessedAt: Double
    ) throws {
        let statement = try prepare(
            """
            UPDATE transcripts SET file_name = ?, last_path = ?, file_size = ?,
                modification_date = ?, last_accessed_at = ? WHERE fingerprint = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(fileName, at: 1, in: statement)
        bind(path, at: 2, in: statement)
        sqlite3_bind_int64(statement, 3, fileSize)
        sqlite3_bind_double(statement, 4, modificationDate)
        sqlite3_bind_double(statement, 5, lastAccessedAt)
        bind(fingerprint, at: 6, in: statement)
        try stepDone(statement)
    }

    private static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("In-Out", isDirectory: true)
            .appendingPathComponent("Transcript Library.sqlite")
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw TranscriptLibraryError.database("Database is closed") }
        try Self.execute(on: database, sql: sql)
    }

    private static func execute(on database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw TranscriptLibraryError.database(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw TranscriptLibraryError.database("Database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw TranscriptLibraryError.database(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite operation failed"
            throw TranscriptLibraryError.database(message)
        }
    }

    private func bind(_ text: String, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, text, -1, Self.sqliteTransient)
    }

    private func text(at index: Int32, in statement: OpaquePointer) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func blob(at index: Int32, in statement: OpaquePointer) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}
