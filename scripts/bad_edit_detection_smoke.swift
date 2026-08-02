import Foundation
import InOutCore

@main
struct BadEditDetectionSmoke {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 7 else {
            throw SmokeFailure("Expected six generated bad-edit fixture paths.")
        }

        try assertFixture(path: arguments[1], contains: .visualFlash)
        try assertFixture(path: arguments[1], excludes: .suspiciouslyShortShot)
        try assertFixture(path: arguments[2], contains: .blackFlash)
        try assertMergedFreeze(path: arguments[3])
        try assertFixture(path: arguments[4], contains: .streamMismatch)
        try assertFixture(path: arguments[5], contains: .abruptAudioDiscontinuity)
        try assertFixture(path: arguments[6], contains: .suspiciouslyShortShot)
        try assertFixture(path: arguments[6], contains: .audioClippingAtEditPoint)

        let cancellationResult = detectPossibleBadEdits(
            file: URL(fileURLWithPath: arguments[1]),
            shouldCancel: { true }
        )
        guard case .failure(.cancelled) = cancellationResult else {
            throw SmokeFailure("Detector did not honor cancellation.")
        }
        print("Bad-edit detection smoke test passed.")
    }

    private static func assertFixture(path: String, contains expected: BadEditIssueKind) throws {
        switch detectPossibleBadEdits(file: URL(fileURLWithPath: path)) {
        case .success(let issues):
            guard issues.contains(where: { $0.kind == expected }) else {
                let found = issues.map(\.kind.rawValue).joined(separator: ", ")
                throw SmokeFailure("Expected \(expected.rawValue) in \(path); found: \(found)")
            }
        case .failure(let error):
            throw SmokeFailure("Detector failed for \(path): \(error)")
        }
    }

    private static func assertFixture(path: String, excludes unexpected: BadEditIssueKind) throws {
        switch detectPossibleBadEdits(file: URL(fileURLWithPath: path)) {
        case .success(let issues):
            guard !issues.contains(where: { $0.kind == unexpected }) else {
                throw SmokeFailure("Unexpected \(unexpected.rawValue) in \(path)")
            }
        case .failure(let error):
            throw SmokeFailure("Detector failed for \(path): \(error)")
        }
    }

    private static func assertMergedFreeze(path: String) throws {
        switch detectPossibleBadEdits(file: URL(fileURLWithPath: path)) {
        case .success(let issues):
            let freezes = issues.filter { $0.kind == .frozenVideo }
            guard freezes.count == 1, freezes[0].duration >= 3 else {
                throw SmokeFailure("Adjacent visually equivalent freezes were not merged: \(freezes.map(\.formatted))")
            }
        case .failure(let error):
            throw SmokeFailure("Detector failed for \(path): \(error)")
        }
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
