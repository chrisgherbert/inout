import AVFoundation
import CoreGraphics
import Foundation

private enum SmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

private struct RenderedFrame {
    let data: Data
    let actualTime: CMTime
}

private func renderedFrame(asset: AVAsset, at time: CMTime) throws -> RenderedFrame {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    var actualTime = CMTime.invalid
    let image = try generator.copyCGImage(at: time, actualTime: &actualTime)
    guard let providerData = image.dataProvider?.data else {
        throw SmokeFailure.failed("Unable to read rendered frame pixels")
    }
    return RenderedFrame(data: providerData as Data, actualTime: actualTime)
}

private func exportPassthrough(asset: AVAsset, timeRange: CMTimeRange, to outputURL: URL) async throws {
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
        throw SmokeFailure.failed("Unable to create passthrough export session")
    }
    session.outputURL = outputURL
    session.outputFileType = .mp4
    session.shouldOptimizeForNetworkUse = true
    session.timeRange = timeRange

    await withCheckedContinuation { continuation in
        session.exportAsynchronously {
            continuation.resume()
        }
    }
    guard session.status == .completed else {
        throw SmokeFailure.failed(session.error?.localizedDescription ?? "Passthrough export failed")
    }
}

@main
private struct FastExportRangeSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw SmokeFailure.failed("Expected source and output paths")
        }

        let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        try? FileManager.default.removeItem(at: outputURL)
        let asset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let selectedStart = 3.237_419
        let selectedEnd = 6.413_781
        let selectedStartTime = CMTime(value: 3_237_419, timescale: 1_000_000)
        let sourceFrame = try renderedFrame(asset: asset, at: selectedStartTime)
        let timeRange = await FastExportUtilities.exportTimeRange(
            for: asset,
            selectedStartSeconds: selectedStart,
            selectedEndSeconds: selectedEnd
        )
        let expandedStart = CMTimeGetSeconds(timeRange.start)
        let expandedEnd = CMTimeGetSeconds(timeRange.end)
        guard expandedStart <= selectedStart,
              expandedEnd >= selectedEnd,
              selectedStart - expandedStart > 3.0 else {
            throw SmokeFailure.failed("Fast export did not expand to cover the selected range")
        }

        try await exportPassthrough(asset: asset, timeRange: timeRange, to: outputURL)

        let outputAsset = AVURLAsset(url: outputURL)
        let outputFrame = try renderedFrame(asset: outputAsset, at: .zero)
        let sourceStartFrame = try renderedFrame(asset: asset, at: timeRange.start)
        guard sourceStartFrame.data == outputFrame.data else {
            throw SmokeFailure.failed("Exported clip does not begin on its preceding sync frame")
        }

        let requestedFrameInOutput = try renderedFrame(
            asset: outputAsset,
            at: CMTimeSubtract(selectedStartTime, timeRange.start)
        )
        guard sourceFrame.data == requestedFrameInOutput.data else {
            throw SmokeFailure.failed("Exported clip omitted the frame displayed at the requested In point")
        }

        let selectedEndTime = CMTime(value: 6_413_781, timescale: 1_000_000)
        let sourceEndFrame = try renderedFrame(asset: asset, at: selectedEndTime)
        let requestedEndFrameInOutput = try renderedFrame(
            asset: outputAsset,
            at: CMTimeSubtract(selectedEndTime, timeRange.start)
        )
        guard sourceEndFrame.data == requestedEndFrameInOutput.data else {
            throw SmokeFailure.failed("Exported clip omitted the frame displayed at the requested Out point")
        }

        let outputDuration = try await outputAsset.load(.duration)
        let expectedDuration = expandedEnd - expandedStart
        guard abs(CMTimeGetSeconds(outputDuration) - expectedDuration) < 0.001_1 else {
            throw SmokeFailure.failed("Exported duration does not match the expanded safe range")
        }

        let exactKeyframeRange = await FastExportUtilities.exportTimeRange(
            for: asset,
            selectedStartSeconds: 4.004,
            selectedEndSeconds: 6.400
        )
        guard abs(CMTimeGetSeconds(exactKeyframeRange.start) - 4.004) < 0.000_001 else {
            throw SmokeFailure.failed("A full-sync In point was unnecessarily expanded to an earlier GOP")
        }

        let laterSelectedStart = 6.237
        let laterSelectedEnd = 7.200
        let laterRange = await FastExportUtilities.exportTimeRange(
            for: asset,
            selectedStartSeconds: laterSelectedStart,
            selectedEndSeconds: laterSelectedEnd
        )
        let laterExpandedStart = CMTimeGetSeconds(laterRange.start)
        guard laterExpandedStart > 3.9,
              laterExpandedStart < laterSelectedStart else {
            throw SmokeFailure.failed("A later In point did not use its nearest preceding sync frame")
        }

        let laterOutputURL = outputURL
            .deletingPathExtension()
            .appendingPathExtension("later.mp4")
        try? FileManager.default.removeItem(at: laterOutputURL)
        try await exportPassthrough(asset: asset, timeRange: laterRange, to: laterOutputURL)
        let laterSourceStartFrame = try renderedFrame(asset: asset, at: laterRange.start)
        let laterOutputStartFrame = try renderedFrame(
            asset: AVURLAsset(url: laterOutputURL),
            at: .zero
        )
        guard laterSourceStartFrame.data == laterOutputStartFrame.data else {
            throw SmokeFailure.failed("Later Fast export does not begin on its preceding sync frame")
        }

        print("Fast export range smoke test passed.")
    }
}
