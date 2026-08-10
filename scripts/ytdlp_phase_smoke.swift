import Foundation
import InOutCore

private struct PhaseFixture {
    let line: String
    let expected: YTDLPDownloadPhase?
}

private let fixtures = [
    PhaseFixture(line: "[Cookies] Extracting cookies from chrome", expected: .loadingCookies),
    PhaseFixture(line: "Extracted 842 cookies from chrome", expected: .loadingCookies),
    PhaseFixture(line: "[youtube] Extracting URL: https://www.youtube.com/watch?v=test", expected: .connecting),
    PhaseFixture(line: "[youtube] test: Downloading webpage", expected: .fetchingMetadata),
    PhaseFixture(line: "[youtube] test: Downloading tv player API JSON", expected: .fetchingMetadata),
    PhaseFixture(line: "[youtube] [jsc:deno] Solving JS challenges using deno", expected: .solvingChallenge),
    PhaseFixture(line: "[info] test: Downloading 1 format(s): 137+140", expected: .selectingFormat),
    PhaseFixture(line: "[download] Destination: example.f137.mp4", expected: .downloading),
    PhaseFixture(line: "download: 12.4%", expected: .downloading),
    PhaseFixture(line: "WARNING: This is unrelated", expected: nil)
]

for fixture in fixtures {
    let actual = YTDLPDownloadPhase.detect(in: fixture.line)
    guard actual == fixture.expected else {
        fputs("Expected \(String(describing: fixture.expected)), got \(String(describing: actual)) for: \(fixture.line)\n", stderr)
        exit(1)
    }
}

print("yt-dlp phase smoke test passed (\(fixtures.count) fixtures).")
