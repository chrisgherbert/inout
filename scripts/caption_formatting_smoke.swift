import Foundation
import InOutCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("Caption formatting smoke test failed: \(message)\n", stderr)
        exit(1)
    }
}

let words = [
    TranscriptWordTiming(word: "Before", start: 9.5, end: 9.9),
    TranscriptWordTiming(word: "This", start: 10.1, end: 10.4),
    TranscriptWordTiming(word: "is", start: 10.4, end: 10.6),
    TranscriptWordTiming(word: "a", start: 10.6, end: 10.7),
    TranscriptWordTiming(word: "readable", start: 10.7, end: 11.2),
    TranscriptWordTiming(word: "caption.", start: 11.2, end: 11.8),
    TranscriptWordTiming(word: "It", start: 12.0, end: 12.2),
    TranscriptWordTiming(word: "has", start: 12.2, end: 12.4),
    TranscriptWordTiming(word: "accurate", start: 12.4, end: 12.9),
    TranscriptWordTiming(word: "timing.", start: 12.9, end: 13.5),
    TranscriptWordTiming(word: "After", start: 15.1, end: 15.4)
]
let segment = TranscriptSegment(start: 9.5, end: 15.4, text: "fixture", timedWords: words)
let cues = makeBurnInCaptionCues(from: [segment], sourceStart: 10, sourceEnd: 15)

require(!cues.isEmpty, "expected caption cues")
require(abs(cues[0].start - 0.1) < 0.001, "clip-relative timing was not rebased")
require(cues.allSatisfy { $0.start >= 0 && $0.end <= 5.001 }, "cue escaped the clip range")
require(cues.allSatisfy { $0.end > $0.start }, "cue duration must be positive")
require(cues.allSatisfy { $0.text.split(separator: "\n").count <= 2 }, "cue exceeded two lines")
require(cues.flatMap { $0.text.split(separator: "\n") }.allSatisfy { $0.count <= 42 }, "caption line exceeded 42 characters")
require(!cues.contains { $0.text.contains("Before") || $0.text.contains("After") }, "out-of-range words were included")

let srt = burnInCaptionSRT(from: cues)
require(srt.contains("00:00:00,100"), "SRT did not preserve rebased milliseconds")
require(srt.contains("-->"), "SRT cue separator missing")

let punctuationWords = [
    TranscriptWordTiming(word: "Hello", start: 0, end: 0.4),
    TranscriptWordTiming(word: ",", start: 0.4, end: 0.45),
    TranscriptWordTiming(word: "world", start: 0.45, end: 0.9),
    TranscriptWordTiming(word: "!", start: 0.9, end: 1.0)
]
let punctuationCues = makeBurnInCaptionCues(
    from: [TranscriptSegment(start: 0, end: 1, text: "fixture", timedWords: punctuationWords)],
    sourceStart: 0,
    sourceEnd: 1
)
require(punctuationCues.first?.text == "Hello, world!", "punctuation spacing was not normalized")

print("Caption formatting smoke test passed.")
