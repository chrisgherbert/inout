import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public let minDurationSeconds = 0.001
public let silenceAmplitudeThreshold = 0.01

let picThreshold = 0.90
let pixelBlackThreshold = 0.10
private let maxSampleDimension = 640
private let quickSampleDimension = 160
private let quickDecisionMargin = 0.08

private func blackPixelRatio(
    imageBuffer: CVImageBuffer,
    maxDimension: Int
) -> Double {
    CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else { return 0 }
    let width = CVPixelBufferGetWidth(imageBuffer)
    let height = CVPixelBufferGetHeight(imageBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
    let threshold = 255.0 * pixelBlackThreshold

    let sampleWidth = min(width, maxDimension)
    let sampleHeight = min(height, maxDimension)
    let stepX = max(1, width / max(sampleWidth, 1))
    let stepY = max(1, height / max(sampleHeight, 1))

    var blackPixels = 0
    var totalPixels = 0

    for y in stride(from: 0, to: height, by: stepY) {
        let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in stride(from: 0, to: width, by: stepX) {
            let pixel = row.advanced(by: x * 4)
            let b = Double(pixel[0])
            let g = Double(pixel[1])
            let r = Double(pixel[2])
            if r <= threshold && g <= threshold && b <= threshold {
                blackPixels += 1
            }
            totalPixels += 1
        }
    }

    guard totalPixels > 0 else { return 0 }
    return Double(blackPixels) / Double(totalPixels)
}

func isFrameMostlyBlack(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
    let quickRatio = blackPixelRatio(imageBuffer: imageBuffer, maxDimension: quickSampleDimension)
    if quickRatio >= (picThreshold + quickDecisionMargin) {
        return true
    }
    if quickRatio <= (picThreshold - quickDecisionMargin) {
        return false
    }

    let ratio = blackPixelRatio(imageBuffer: imageBuffer, maxDimension: maxSampleDimension)
    return ratio >= picThreshold
}

func buildSegments(blackIntervals: [(start: Double, end: Double)], minDuration: Double) -> [Segment] {
    blackIntervals.compactMap { interval in
        let duration = interval.end - interval.start
        guard duration >= minDuration else { return nil }
        return Segment(start: interval.start, end: interval.end, duration: duration)
    }
}
