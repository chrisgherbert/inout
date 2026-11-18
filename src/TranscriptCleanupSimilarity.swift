import Foundation

/// Reject large spelling changes that can substitute unrelated wording. This is a
/// text safeguard, not verification against the audio; short names remain reviewable.
enum TranscriptCleanupSimilarity {
    static func allows(original: String, replacement: String) -> Bool {
        var beforeWords = original.split(whereSeparator: \.isWhitespace).map(String.init)
        var afterWords = replacement.split(whereSeparator: \.isWhitespace).map(String.init)

        // Unchanged context must not hide an unrelated substitution inside a long edit.
        while let before = beforeWords.first, let after = afterWords.first,
              compact(before) == compact(after) {
            beforeWords.removeFirst()
            afterWords.removeFirst()
        }
        while let before = beforeWords.last, let after = afterWords.last,
              compact(before) == compact(after) {
            beforeWords.removeLast()
            afterWords.removeLast()
        }

        let before = Array(compact(beforeWords.joined()))
        let after = Array(compact(afterWords.joined()))
        if before == after { return true }

        // Character distance is unreliable for short aliases and phonetic spellings.
        let length = max(before.count, after.count)
        guard length >= 8, min(before.count, after.count) >= 4 else { return true }
        if initials(beforeWords) == String(after) || initials(afterWords) == String(before) {
            return true
        }

        var previous = Array(0...after.count)
        for (beforeIndex, beforeCharacter) in before.enumerated() {
            var current = [beforeIndex + 1]
            for (afterIndex, afterCharacter) in after.enumerated() {
                current.append(min(
                    previous[afterIndex + 1] + 1,
                    current[afterIndex] + 1,
                    previous[afterIndex] + (beforeCharacter == afterCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return Double(previous.last!) / Double(length) <= 0.6
    }

    private static func compact(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func initials(_ words: [String]) -> String {
        words.compactMap { compact($0).first }.map(String.init).joined()
    }
}
