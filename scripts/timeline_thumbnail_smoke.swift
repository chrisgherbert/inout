import CoreGraphics
import Foundation

@main
struct TimelineThumbnailSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeFailure("Expected a synthetic video path.")
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let duration = 12.0

        async let first = generateTimelineThumbnailStripImage(
            fileURL: url,
            visibleStartSeconds: 0,
            visibleEndSeconds: 3,
            totalDurationSeconds: duration,
            pixelWidth: 800,
            pixelHeight: 96
        )
        async let second = generateTimelineThumbnailStripImage(
            fileURL: url,
            visibleStartSeconds: 3,
            visibleEndSeconds: 6,
            totalDurationSeconds: duration,
            pixelWidth: 800,
            pixelHeight: 96
        )
        async let third = generateTimelineThumbnailStripImage(
            fileURL: url,
            visibleStartSeconds: 6,
            visibleEndSeconds: 9,
            totalDurationSeconds: duration,
            pixelWidth: 800,
            pixelHeight: 96
        )

        let generated = await [first, second, third]
        guard generated.allSatisfy({ $0 != nil }) else {
            throw SmokeFailure("Concurrent thumbnail generation returned a missing strip.")
        }

        let cancellationStart = ContinuousClock.now
        let cancellationTask = Task.detached {
            await generateTimelineThumbnailStripImage(
                fileURL: url,
                visibleStartSeconds: 0,
                visibleEndSeconds: duration,
                totalDurationSeconds: duration,
                pixelWidth: 16_000,
                pixelHeight: 180,
                shouldCancel: { Task.isCancelled }
            )
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
        cancellationTask.cancel()
        let cancelledResult = await cancellationTask.value
        let cancellationElapsed = cancellationStart.duration(to: .now)
        guard cancelledResult == nil else {
            throw SmokeFailure("Cancelled thumbnail generation unexpectedly returned an image.")
        }
        guard cancellationElapsed < .seconds(2) else {
            throw SmokeFailure("Cancelled thumbnail generation did not finish promptly.")
        }

        let baseKey = timelineThumbnailStripCacheKey(
            for: url,
            visibleStartSeconds: 0,
            visibleEndSeconds: 3,
            pixelWidth: 800,
            pixelHeight: 96
        )
        let zoomedKey = timelineThumbnailStripCacheKey(
            for: url,
            visibleStartSeconds: 0,
            visibleEndSeconds: 1.5,
            pixelWidth: 800,
            pixelHeight: 96
        )
        guard baseKey != zoomedKey else {
            throw SmokeFailure("Different zoom ranges produced the same strip cache key.")
        }

        print("Timeline thumbnail smoke test passed.")
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
