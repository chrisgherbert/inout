import Foundation

public struct BurnInCaptionCue: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

private struct CaptionWord {
    let text: String
    let start: Double
    let end: Double
}

public func transcriptHasWordTimings(_ segments: [TranscriptSegment]) -> Bool {
    !segments.isEmpty && segments.allSatisfy { !$0.timedWords.isEmpty }
}

public func makeBurnInCaptionCues(
    from segments: [TranscriptSegment],
    sourceStart: Double,
    sourceEnd: Double,
    maximumCharactersPerLine: Int = 42,
    maximumLines: Int = 2,
    maximumDuration: Double = 5.0
) -> [BurnInCaptionCue] {
    let rangeStart = max(0, sourceStart)
    let rangeEnd = max(rangeStart, sourceEnd)
    guard rangeEnd > rangeStart else { return [] }

    let words = segments
        .flatMap(\.timedWords)
        .filter { $0.end > rangeStart && $0.start < rangeEnd && !$0.word.isEmpty }
        .map { timing in
            CaptionWord(
                text: timing.word,
                start: max(rangeStart, timing.start) - rangeStart,
                end: min(rangeEnd, max(timing.start + 0.05, timing.end)) - rangeStart
            )
        }
        .sorted {
            if abs($0.start - $1.start) > 0.0001 { return $0.start < $1.start }
            return $0.end < $1.end
        }

    guard !words.isEmpty else { return [] }

    var cues: [BurnInCaptionCue] = []
    var current: [CaptionWord] = []

    func normalizedText(for words: [CaptionWord]) -> String {
        var text = words.map(\.text).joined(separator: " ")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\(\s+"#, with: "(", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+\)"#, with: ")", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func wrappedLines(for words: [CaptionWord]) -> [String] {
        let normalized = normalizedText(for: words)
        if normalized.count <= maximumCharactersPerLine { return normalized.isEmpty ? [] : [normalized] }
        let tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        if tokens.count == 1 { return tokens }

        var best: [String]?
        var bestScore = Int.max
        for splitIndex in 1..<tokens.count {
            let first = tokens[..<splitIndex].joined(separator: " ")
            let second = tokens[splitIndex...].joined(separator: " ")
            guard first.count <= maximumCharactersPerLine,
                  second.count <= maximumCharactersPerLine else { continue }
            let score = max(first.count, second.count) * 10 + abs(first.count - second.count)
            if score < bestScore {
                best = [first, second]
                bestScore = score
            }
        }
        if let best { return best }

        var lines: [String] = []
        for token in tokens {
            if let last = lines.last,
               last.count + 1 + token.count <= maximumCharactersPerLine {
                lines[lines.index(before: lines.endIndex)] = last + " " + token
            } else {
                lines.append(token)
            }
        }
        return lines
    }

    func flush() {
        guard let first = current.first, let last = current.last else { return }
        let lines = wrappedLines(for: current)
        guard !lines.isEmpty else {
            current.removeAll(keepingCapacity: true)
            return
        }
        let relativeRangeEnd = rangeEnd - rangeStart
        let cueStart = min(max(0, first.start), max(0, relativeRangeEnd - 0.05))
        let cueEnd = min(relativeRangeEnd, max(last.end, cueStart + 0.8))
        cues.append(
            BurnInCaptionCue(
                start: cueStart,
                end: max(cueStart + 0.05, cueEnd),
                text: lines.joined(separator: "\n")
            )
        )
        current.removeAll(keepingCapacity: true)
    }

    for word in words {
        if let previous = current.last {
            let candidate = current + [word]
            let gap = word.start - previous.end
            let candidateDuration = word.end - (current.first?.start ?? word.start)
            let previousEndsSentence = previous.text.last.map { ".!?".contains($0) } ?? false
            let candidateLines = wrappedLines(for: candidate)
            let shouldBreak = gap > 0.75
                || candidateDuration > maximumDuration
                || candidateLines.count > maximumLines
                || (previousEndsSentence && current.count >= 3)
            if shouldBreak {
                flush()
            }
        }

        current.append(word)

        let text = normalizedText(for: current)
        let duration = (current.last?.end ?? word.end) - (current.first?.start ?? word.start)
        if duration >= 1.2,
           text.count >= 24,
           text.last.map({ ".!?".contains($0) }) == true {
            flush()
        }
    }
    flush()

    guard cues.count > 1 else { return cues }
    return cues.enumerated().map { index, cue in
        let nextStart = index + 1 < cues.count ? cues[index + 1].start : rangeEnd - rangeStart
        let nonOverlappingEnd = min(cue.end, nextStart)
        return BurnInCaptionCue(
            start: cue.start,
            end: max(cue.start + 0.05, nonOverlappingEnd),
            text: cue.text
        )
    }
}

public func burnInCaptionSRT(from cues: [BurnInCaptionCue]) -> String {
    func timestamp(_ seconds: Double) -> String {
        let milliseconds = Int((max(0, seconds) * 1000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let wholeSeconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, wholeSeconds, remainder)
    }

    return cues.enumerated().map { index, cue in
        """
        \(index + 1)
        \(timestamp(cue.start)) --> \(timestamp(cue.end))
        \(cue.text)
        """
    }
    .joined(separator: "\n\n") + (cues.isEmpty ? "" : "\n")
}
