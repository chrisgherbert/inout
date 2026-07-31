#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/main.swift" <<'SWIFT'
import AppKit

let short = transcriptSegmentRowHeight(
    text: "A short transcript paragraph.",
    textWidth: 360,
    fontSize: 13
)
let longText = String(
    repeating: "A longer transcript paragraph should wrap naturally without changing its timestamp. ",
    count: 8
)
let longWide = transcriptSegmentRowHeight(text: longText, textWidth: 520, fontSize: 13)
let longNarrow = transcriptSegmentRowHeight(text: longText, textWidth: 240, fontSize: 13)

precondition(short >= 30, "Paragraph rows must preserve the minimum target height")
precondition(longWide > short, "Long paragraphs must grow vertically")
precondition(longNarrow > longWide, "Narrower paragraphs must wrap to a greater height")

func timedWords(
    _ values: [String],
    sourceID: UUID,
    start: Double,
    spacing: Double = 0.32
) -> [TranscriptTimedWordUnit] {
    values.enumerated().map { index, value in
        let wordStart = start + (Double(index) * spacing)
        return TranscriptTimedWordUnit(
            sourceSegmentID: sourceID,
            text: value,
            start: wordStart,
            end: wordStart + 0.22
        )
    }
}

let abbreviationID = UUID()
let abbreviationWords = timedWords(
    ["Dr.", "Smith", "opened", "the", "hearing.", "The", "committee", "then", "voted."],
    sourceID: abbreviationID,
    start: 0
)
let abbreviationSentences = makeTranscriptSentences(from: abbreviationWords)
precondition(abbreviationSentences.count == 2, "Abbreviations must not create false sentence boundaries")
precondition(abbreviationSentences[0].text.hasPrefix("Dr. Smith"), "Sentence text must retain the abbreviation")

let firstID = UUID()
let secondID = UUID()
let thirdID = UUID()
let fourthID = UUID()
let fifthID = UUID()
let sixthID = UUID()
let words =
    timedWords(["The", "host", "introduced", "the", "first", "major", "topic", "clearly."], sourceID: firstID, start: 0) +
    timedWords(["The", "guest", "explained", "why", "the", "proposal", "had", "changed."], sourceID: secondID, start: 3) +
    timedWords(["They", "finished", "that", "discussion", "with", "a", "short", "summary."], sourceID: thirdID, start: 6) +
    timedWords(["Now", "the", "conversation", "turned", "to", "a", "different", "subject."], sourceID: fourthID, start: 8.8) +
    timedWords(["The", "new", "topic", "continued", "through", "the", "next", "exchange."], sourceID: fifthID, start: 11.8) +
    timedWords(["After", "the", "break", "the", "host", "began", "the", "conclusion."], sourceID: sixthID, start: 16.8)

let paragraphs = makeOptimizedTranscriptParagraphs(from: words)
precondition(
    paragraphs.count == 3,
    "Discourse transitions and strong pauses should create distinct paragraphs: \(paragraphs.map { $0.sourceSegmentIDs.count })"
)
precondition(paragraphs[0].sourceSegmentIDs == [firstID, secondID, thirdID], "The first topic must stay together")
precondition(paragraphs[1].sourceSegmentIDs == [fourthID, fifthID], "The second topic must stay together")
precondition(paragraphs[2].sourceSegmentIDs == [sixthID], "A strong pause must start a new paragraph")
precondition(abs(paragraphs[0].start - 0) < 0.001, "Paragraph timing must use the first timed word")
precondition(abs(paragraphs[1].start - 8.8) < 0.001, "Paragraph timing must survive optimization")
precondition(
    paragraphs.reduce(into: Set<UUID>()) { $0.formUnion($1.sourceSegmentIDs) } ==
        [firstID, secondID, thirdID, fourthID, fifthID, sixthID],
    "Every source segment must remain represented"
)

let singleSourceID = UUID()
let singleSourceWords = (0..<12).flatMap { sentenceIndex in
    timedWords(
        ["This", "is", "sentence", "number", "\(sentenceIndex + 1)", "in", "one", "source."],
        sourceID: singleSourceID,
        start: Double(sentenceIndex) * 2.8
    )
}
let singleSourceParagraphs = makeOptimizedTranscriptParagraphs(from: singleSourceWords)
precondition(
    singleSourceParagraphs.count >= 3,
    "A long single source segment must still split into multiple paragraphs"
)
precondition(
    singleSourceParagraphs.allSatisfy { $0.sourceSegmentIDs == [singleSourceID] },
    "Splitting a source segment must retain its source identity"
)

print("Transcript paragraph layout smoke test passed")
SWIFT

swiftc \
    "$ROOT_DIR/src/TranscriptLayoutUtilities.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/transcript-paragraph-layout-smoke"
"$TMP_DIR/transcript-paragraph-layout-smoke"
