import AppKit
import NaturalLanguage

struct TranscriptTimedWordUnit: Equatable {
    let sourceSegmentID: UUID
    let text: String
    let start: Double
    let end: Double
}

struct TranscriptSentenceUnit: Equatable {
    let text: String
    let start: Double
    let end: Double
    let wordCount: Int
    let sourceSegmentIDs: Set<UUID>
}

struct TranscriptParagraphUnit: Equatable {
    let text: String
    let start: Double
    let end: Double
    let sourceSegmentIDs: Set<UUID>
}

func makeTranscriptSentences(
    from proposedWords: [TranscriptTimedWordUnit]
) -> [TranscriptSentenceUnit] {
    let words = proposedWords
        .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .sorted {
            if abs($0.start - $1.start) > 0.000_1 { return $0.start < $1.start }
            return $0.end < $1.end
        }
    guard !words.isEmpty else { return [] }

    var text = ""
    var ranges: [Range<String.Index>] = []
    ranges.reserveCapacity(words.count)
    for word in words {
        let normalized = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, transcriptWordNeedsLeadingSpace(normalized) {
            text.append(" ")
        }
        let start = text.endIndex
        text.append(normalized)
        ranges.append(start..<text.endIndex)
    }

    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    var sentences: [TranscriptSentenceUnit] = []
    var nextWordIndex = 0
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { sentenceRange, _ in
        while nextWordIndex < ranges.count, ranges[nextWordIndex].upperBound <= sentenceRange.lowerBound {
            nextWordIndex += 1
        }
        let firstWordIndex = nextWordIndex
        var endWordIndex = firstWordIndex
        while endWordIndex < ranges.count, ranges[endWordIndex].lowerBound < sentenceRange.upperBound {
            endWordIndex += 1
        }
        guard firstWordIndex < endWordIndex else { return true }
        appendTranscriptSentence(
            words: Array(words[firstWordIndex..<endWordIndex]),
            text: String(text[sentenceRange]),
            to: &sentences
        )
        nextWordIndex = endWordIndex
        return true
    }

    if sentences.isEmpty {
        appendTranscriptSentence(words: words, text: text, to: &sentences)
    }
    return splitOversizedTranscriptSentences(sentences, sourceWords: words)
}

func makeOptimizedTranscriptParagraphs(
    from words: [TranscriptTimedWordUnit]
) -> [TranscriptParagraphUnit] {
    let sentences = makeTranscriptSentences(from: words)
    guard !sentences.isEmpty else { return [] }

    let count = sentences.count
    var bestCosts = Array(repeating: Double.greatestFiniteMagnitude, count: count + 1)
    var nextIndexes = Array(repeating: count, count: count + 1)
    bestCosts[count] = 0

    for startIndex in stride(from: count - 1, through: 0, by: -1) {
        var wordCount = 0
        var characterCount = 0
        var sourceIDs: Set<UUID> = []

        for endIndex in startIndex..<min(count, startIndex + 6) {
            if endIndex > startIndex {
                let previous = sentences[endIndex - 1]
                let current = sentences[endIndex]
                if transcriptBoundaryPause(previous: previous, next: current) >= 1.45 {
                    break
                }
            }

            let sentence = sentences[endIndex]
            wordCount += sentence.wordCount
            characterCount += sentence.text.count + (endIndex > startIndex ? 1 : 0)
            sourceIDs.formUnion(sentence.sourceSegmentIDs)
            let duration = max(0, sentence.end - sentences[startIndex].start)
            if endIndex > startIndex && (wordCount > 120 || characterCount > 720 || duration > 42) {
                break
            }

            let nextIndex = endIndex + 1
            let groupCost = transcriptParagraphGroupCost(
                sentenceCount: endIndex - startIndex + 1,
                wordCount: wordCount,
                characterCount: characterCount,
                duration: duration
            )
            let boundaryCost = transcriptParagraphBoundaryCost(
                previous: sentence,
                next: nextIndex < count ? sentences[nextIndex] : nil
            )
            let totalCost = groupCost + boundaryCost + bestCosts[nextIndex]
            if totalCost < bestCosts[startIndex] {
                bestCosts[startIndex] = totalCost
                nextIndexes[startIndex] = nextIndex
            }
        }
    }

    var paragraphs: [TranscriptParagraphUnit] = []
    var index = 0
    while index < count {
        let nextIndex = max(index + 1, min(count, nextIndexes[index]))
        let group = sentences[index..<nextIndex]
        paragraphs.append(
            TranscriptParagraphUnit(
                text: group.map(\.text).joined(separator: " "),
                start: group.first?.start ?? 0,
                end: group.last?.end ?? 0,
                sourceSegmentIDs: group.reduce(into: Set<UUID>()) {
                    $0.formUnion($1.sourceSegmentIDs)
                }
            )
        )
        index = nextIndex
    }
    return paragraphs
}

private func transcriptWordNeedsLeadingSpace(_ word: String) -> Bool {
    guard let first = word.first else { return false }
    return !",.;:!?%)]}”’".contains(first)
}

private func appendTranscriptSentence(
    words: [TranscriptTimedWordUnit],
    text: String,
    to sentences: inout [TranscriptSentenceUnit]
) {
    guard let first = words.first, let last = words.last else { return }
    let normalizedText = text.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedText.isEmpty else { return }
    sentences.append(
        TranscriptSentenceUnit(
            text: normalizedText,
            start: first.start,
            end: max(first.start + 0.05, last.end),
            wordCount: words.count,
            sourceSegmentIDs: Set(words.map(\.sourceSegmentID))
        )
    )
}

private func splitOversizedTranscriptSentences(
    _ sentences: [TranscriptSentenceUnit],
    sourceWords: [TranscriptTimedWordUnit]
) -> [TranscriptSentenceUnit] {
    var result: [TranscriptSentenceUnit] = []
    for sentence in sentences {
        guard sentence.wordCount > 90 || sentence.end - sentence.start > 35 else {
            result.append(sentence)
            continue
        }
        let words = sourceWords.filter {
            $0.start >= sentence.start - 0.001 && $0.end <= sentence.end + 0.001
        }
        guard words.count > 1 else {
            result.append(sentence)
            continue
        }

        var startIndex = 0
        while startIndex < words.count {
            let upperLimit = min(words.count, startIndex + 70)
            var splitIndex = upperLimit
            if upperLimit < words.count {
                let searchStart = min(upperLimit - 1, startIndex + 35)
                if searchStart < upperLimit {
                    let strongest = (searchStart..<upperLimit).max {
                        (words[$0 + 1].start - words[$0].end) <
                            (words[$1 + 1].start - words[$1].end)
                    }
                    if let strongest {
                        splitIndex = strongest + 1
                    }
                }
            }
            let chunk = Array(words[startIndex..<splitIndex])
            appendTranscriptSentence(
                words: chunk,
                text: chunk.map(\.text).joined(separator: " "),
                to: &result
            )
            startIndex = splitIndex
        }
    }
    return result
}

private func transcriptParagraphGroupCost(
    sentenceCount: Int,
    wordCount: Int,
    characterCount: Int,
    duration: Double
) -> Double {
    let sentencePenalty: Double
    switch sentenceCount {
    case 1: sentencePenalty = 2.4
    case 2: sentencePenalty = 0.45
    case 3: sentencePenalty = 0
    case 4: sentencePenalty = 0.35
    default: sentencePenalty = 3.2
    }

    let durationPenalty = pow((duration - 18) / 16, 2)
    let wordPenalty = pow((Double(wordCount) - 58) / 45, 2) * 0.7
    let characterPenalty = characterCount > 560
        ? pow(Double(characterCount - 560) / 120, 2) * 2
        : 0
    return sentencePenalty + durationPenalty + wordPenalty + characterPenalty
}

private func transcriptParagraphBoundaryCost(
    previous: TranscriptSentenceUnit,
    next: TranscriptSentenceUnit?
) -> Double {
    guard let next else { return -1.5 }
    let pause = transcriptBoundaryPause(previous: previous, next: next)
    var cost = -min(2.5, pause * 1.7)
    if pause < 0.12 {
        cost += 0.55
    }
    if transcriptBeginsWithDiscourseTransition(next.text) {
        cost -= 1.6
    }
    return cost
}

private func transcriptBoundaryPause(
    previous: TranscriptSentenceUnit,
    next: TranscriptSentenceUnit
) -> Double {
    max(0, next.start - previous.end)
}

private func transcriptBeginsWithDiscourseTransition(_ text: String) -> Bool {
    let normalized = text.lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    let transitions = [
        "another ", "anyway", "at the same time", "but ", "finally",
        "however", "meanwhile", "next ", "now ", "on the other hand",
        "the other ", "turning to", "with that said"
    ]
    return transitions.contains { normalized == $0.trimmingCharacters(in: .whitespaces) || normalized.hasPrefix($0) }
}

func transcriptSegmentRowHeight(
    text: String,
    textWidth: CGFloat,
    fontSize: CGFloat
) -> CGFloat {
    let bounds = (text as NSString).boundingRect(
        with: NSSize(width: max(80, textWidth), height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: NSFont.systemFont(ofSize: fontSize)]
    )
    return max(30, ceil(bounds.height) + 11)
}
