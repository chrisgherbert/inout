import Foundation
import InOutCore

struct TranscriptCleanupWord: Sendable {
    let index: Int
    let segmentIndex: Int
    let timing: TranscriptWordTiming
}

struct TranscriptCleanupEdit: Codable, Identifiable, Sendable {
    let startWord: Int
    let endWord: Int
    let original: String
    let replacement: String

    var id: Int { startWord }
}

enum TranscriptCleanupError: LocalizedError {
    case invalidResponse
    case transcriptChanged

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The cleanup response could not be safely matched to the transcript. No changes were applied. Request timing and retry details are in the Activity Console."
        case .transcriptChanged:
            return "The transcript changed during cleanup. Close this window and start again."
        }
    }
}

enum TranscriptCleanup {
    static func words(in segments: [TranscriptSegment]) -> [TranscriptCleanupWord] {
        var words: [TranscriptCleanupWord] = []
        for (segmentIndex, segment) in segments.enumerated() {
            for timing in segment.timedWords {
                words.append(TranscriptCleanupWord(index: words.count, segmentIndex: segmentIndex, timing: timing))
            }
        }
        return words
    }

    static func parse(_ response: String, words: [TranscriptCleanupWord], allowedRange: Range<Int>) throws -> [TranscriptCleanupEdit] {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), let newline = json.firstIndex(of: "\n"), json.hasSuffix("```") {
            json = String(json[json.index(after: newline)..<json.index(json.endIndex, offsetBy: -3)])
        }
        struct Response: Decodable { let edits: [TranscriptCleanupEdit] }
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranscriptCleanupError.invalidResponse
        }
        return try validate(response.edits, words: words, allowedRange: allowedRange)
    }

    static func validate(_ edits: [TranscriptCleanupEdit], words: [TranscriptCleanupWord], allowedRange: Range<Int>) throws -> [TranscriptCleanupEdit] {
        let sorted = edits.sorted { $0.startWord < $1.startWord }
        var previousEnd = -1
        for edit in sorted {
            guard allowedRange.contains(edit.startWord), allowedRange.contains(edit.endWord),
                  edit.startWord > previousEnd, edit.endWord >= edit.startWord,
                  words.indices.contains(edit.startWord), words.indices.contains(edit.endWord),
                  edit.endWord - edit.startWord < 8,
                  words[edit.startWord].segmentIndex == words[edit.endWord].segmentIndex else {
                throw TranscriptCleanupError.invalidResponse
            }
            let original = words[edit.startWord...edit.endWord].map(\.timing.word).joined(separator: " ")
            let replacement = edit.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard edit.original == original, !replacement.isEmpty,
                  replacement == edit.replacement,
                  !replacement.contains(where: \.isNewline),
                  replacement.count <= max(80, original.count * 3),
                  replacement.split(whereSeparator: \.isWhitespace).count <= (edit.endWord - edit.startWord + 1) + 3 else {
                throw TranscriptCleanupError.invalidResponse
            }
            previousEnd = edit.endWord
        }
        return sorted.filter { $0.original != $0.replacement }
    }

    static func applying(_ edits: [TranscriptCleanupEdit], to segments: [TranscriptSegment]) throws -> [TranscriptSegment] {
        let words = words(in: segments)
        let edits = try validate(edits, words: words, allowedRange: words.indices)
        let byStart = Dictionary(uniqueKeysWithValues: edits.map { ($0.startWord, $0) })
        let changedSegments = Set(edits.map { words[$0.startWord].segmentIndex })
        var updatedWords: [Int: [TranscriptWordTiming]] = [:]
        var index = 0
        while index < words.count {
            let word = words[index]
            if let edit = byStart[index] {
                // A corrected phrase keeps its original outer span. Never invent internal timestamps.
                updatedWords[word.segmentIndex, default: []].append(TranscriptWordTiming(
                    word: edit.replacement, start: word.timing.start, end: words[edit.endWord].timing.end
                ))
                index = edit.endWord + 1
            } else {
                updatedWords[word.segmentIndex, default: []].append(word.timing)
                index += 1
            }
        }
        return segments.enumerated().map { segmentIndex, segment in
            guard changedSegments.contains(segmentIndex), let timedWords = updatedWords[segmentIndex] else { return segment }
            return TranscriptSegment(id: segment.id, start: segment.start, end: segment.end,
                                     text: joinedText(timedWords.map(\.word)), timedWords: timedWords)
        }
    }

    static func joinedText(_ words: [String]) -> String {
        words.joined(separator: " ")
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([\(\[])\s+"#, with: "$1", options: .regularExpression)
    }

    // Display comparisons avoid walking every word during playback. Snapshot validation below
    // also checks timings before accepting results from a request.
    static func displayMatches(_ lhs: [TranscriptSegment], _ rhs: [TranscriptSegment]) -> Bool {
        lhs.elementsEqual(rhs) { $0.id == $1.id && $0.text == $1.text }
    }

    static func matches(_ lhs: [TranscriptSegment], _ rhs: [TranscriptSegment]) -> Bool {
        lhs.elementsEqual(rhs) { a, b in
            a.id == b.id && a.text == b.text && a.start == b.start && a.end == b.end &&
            a.timedWords.elementsEqual(b.timedWords) { $0.word == $1.word && $0.start == $1.start && $0.end == $1.end }
        }
    }
}
