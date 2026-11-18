import Foundation

struct TranscriptCleanupPhraseEdit: Codable, Sendable {
    let segments: [Int]
    let from: String
    let to: String
}

struct TranscriptCleanupPhraseResolution: Sendable {
    let edits: [TranscriptCleanupEdit]
    let skipped: Int
}

enum TranscriptCleanupPhrases {
    static func parse(_ response: String, words: [TranscriptCleanupWord], allowedRange: Range<Int>) throws -> [TranscriptCleanupEdit] {
        try resolve(response, words: words, allowedRange: allowedRange).edits
    }

    static func resolve(_ response: String, words: [TranscriptCleanupWord], allowedRange: Range<Int>) throws -> TranscriptCleanupPhraseResolution {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), let newline = json.firstIndex(of: "\n"), json.hasSuffix("```") {
            json = String(json[json.index(after: newline)..<json.index(json.endIndex, offsetBy: -3)])
        }
        struct Response: Decodable { let edits: [TranscriptCleanupPhraseEdit] }
        guard let data = json.data(using: .utf8), let payload = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranscriptCleanupError.invalidResponse
        }
        let bySegment = Dictionary(grouping: words, by: \.segmentIndex)
        var edits: [TranscriptCleanupEdit] = []
        var skipped = 0
        for phrase in payload.edits {
            guard !phrase.from.isEmpty, !phrase.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !phrase.from.contains(where: \.isNewline), !phrase.to.contains(where: \.isNewline),
                  !phrase.segments.isEmpty, Set(phrase.segments).count == phrase.segments.count else {
                skipped += max(1, phrase.segments.count)
                continue
            }
            // Match exact text at letter/number boundaries. The app, not the model,
            // determines the word anchors and carries any surrounding punctuation.
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: phrase.from) + #"(?![\p{L}\p{N}])"#
            let regex = try NSRegularExpression(pattern: pattern)
            for segmentIndex in phrase.segments {
                guard let segmentWords = bySegment[segmentIndex] else { skipped += 1; continue }
                let text = segmentWords.map(\.timing.word).joined(separator: " ") as NSString
                var offset = 0
                let ranges = segmentWords.map { word -> NSRange in
                    let range = NSRange(location: offset, length: word.timing.word.utf16.count)
                    offset += range.length + 1
                    return range
                }
                var matched = false
                for match in regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                    guard let first = ranges.firstIndex(where: { NSIntersectionRange($0, match.range).length > 0 }),
                          let last = ranges.lastIndex(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                    let start = segmentWords[first].index
                    let end = segmentWords[last].index
                    guard allowedRange.contains(start), allowedRange.contains(end) else { continue }
                    let prefix = text.substring(with: NSRange(location: ranges[first].location, length: match.range.location - ranges[first].location))
                    let suffixStart = NSMaxRange(match.range)
                    let suffix = text.substring(with: NSRange(location: suffixStart, length: NSMaxRange(ranges[last]) - suffixStart))
                    guard (prefix + suffix).allSatisfy({ !$0.isLetter && !$0.isNumber }) else { continue }
                    matched = true
                    let edit = TranscriptCleanupEdit(startWord: start, endWord: end,
                        original: segmentWords[first...last].map(\.timing.word).joined(separator: " "),
                        replacement: prefix + phrase.to + suffix)
                    guard TranscriptCleanupSimilarity.allows(original: edit.original, replacement: edit.replacement) else {
                        skipped += 1
                        continue
                    }
                    if let checked = try? TranscriptCleanup.validate([edit], words: words, allowedRange: allowedRange) {
                        edits += checked
                    } else { skipped += 1 }
                }
                if !matched { skipped += 1 }
            }
        }
        // Reject conflicts without throwing away unrelated, verified corrections.
        // Exact duplicates are harmless; overlapping alternatives are all omitted.
        let sorted = edits.sorted { $0.startWord == $1.startWord ? $0.endWord < $1.endWord : $0.startWord < $1.startWord }
        var resolved: [TranscriptCleanupEdit] = []
        var index = 0
        while index < sorted.count {
            let first = sorted[index]
            var end = first.endWord
            var next = index + 1
            while next < sorted.count && sorted[next].startWord <= end {
                end = max(end, sorted[next].endWord)
                next += 1
            }
            let group = sorted[index..<next]
            if group.allSatisfy({ $0.startWord == first.startWord && $0.endWord == first.endWord && $0.replacement == first.replacement }) {
                resolved.append(first)
            } else { skipped += group.count }
            index = next
        }
        return TranscriptCleanupPhraseResolution(
            edits: try TranscriptCleanup.validate(resolved, words: words, allowedRange: allowedRange), skipped: skipped
        )
    }
}
