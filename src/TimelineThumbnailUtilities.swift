import AVFoundation
import CoreGraphics
import Foundation

private final class CachedTimelineThumbnailFrameBox {
    let image: CGImage

    init(image: CGImage) {
        self.image = image
    }
}

private enum TimelineThumbnailFrameCache {
    static let shared: NSCache<NSString, CachedTimelineThumbnailFrameBox> = {
        let cache = NSCache<NSString, CachedTimelineThumbnailFrameBox>()
        cache.countLimit = 640
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    static func image(forKey key: String) -> CGImage? {
        shared.object(forKey: key as NSString)?.image
    }

    static func insert(_ image: CGImage, forKey key: String) {
        let estimatedCost = max(1, image.width * image.height * 4)
        shared.setObject(
            CachedTimelineThumbnailFrameBox(image: image),
            forKey: key as NSString,
            cost: estimatedCost
        )
    }
}

func timelineThumbnailStripCacheKey(
    for url: URL,
    visibleStartSeconds: Double,
    visibleEndSeconds: Double,
    pixelWidth: Int,
    pixelHeight: Int
) -> String {
    let startFrameBucket = Int((visibleStartSeconds * 30.0).rounded())
    let endFrameBucket = Int((visibleEndSeconds * 30.0).rounded())
    return "\(url.path)|\(startFrameBucket)|\(endFrameBucket)|\(pixelWidth)x\(pixelHeight)"
}

private func timelineThumbnailFrameCacheKey(
    for url: URL,
    requestedSeconds: Double,
    bucketSeconds: Double,
    decodeMaximumSize: CGSize
) -> String {
    let safeBucket = max(1.0 / 120.0, bucketSeconds)
    let timeBucket = Int((requestedSeconds / safeBucket).rounded())
    let widthBucket = Int((decodeMaximumSize.width / 24.0).rounded()) * 24
    let heightBucket = Int((decodeMaximumSize.height / 24.0).rounded()) * 24
    return "\(url.path)|t\(timeBucket)|s\(widthBucket)x\(heightBucket)"
}

private func makeThumbnailGenerator(
    asset: AVAsset,
    maximumSize: CGSize,
    tolerance: CMTime
) -> AVAssetImageGenerator {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = maximumSize
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
    return generator
}

private func copyThumbnailImage(
    strictGenerator: AVAssetImageGenerator,
    fallbackGenerator: AVAssetImageGenerator,
    time: CMTime
) -> CGImage? {
    if let strict = try? strictGenerator.copyCGImage(at: time, actualTime: nil) {
        return strict
    }
    return try? fallbackGenerator.copyCGImage(at: time, actualTime: nil)
}

private func estimatedVideoAspectRatio(for asset: AVAsset) -> CGFloat {
    guard let track = asset.tracks(withMediaType: .video).first else { return 16.0 / 9.0 }
    let size = track.naturalSize.applying(track.preferredTransform)
    let width = abs(size.width)
    let height = abs(size.height)
    guard width > 0, height > 0 else { return 16.0 / 9.0 }
    return width / height
}

private func aspectFillRect(for image: CGImage, in destinationRect: CGRect) -> CGRect {
    let imageSize = CGSize(width: image.width, height: image.height)
    guard imageSize.width > 0, imageSize.height > 0, destinationRect.width > 0, destinationRect.height > 0 else {
        return destinationRect
    }

    let scale = max(destinationRect.width / imageSize.width, destinationRect.height / imageSize.height)
    let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(
        x: destinationRect.midX - (scaledSize.width / 2.0),
        y: destinationRect.midY - (scaledSize.height / 2.0),
        width: scaledSize.width,
        height: scaledSize.height
    )
}

private func thumbnailDecodeMaximumSize(
    aspectRatio: CGFloat,
    tileWidth: CGFloat,
    pixelHeight: Int
) -> CGSize {
    let destinationHeight = max(1, CGFloat(pixelHeight))
    let overscan: CGFloat = 1.12

    // Decode close to the final on-screen size, while leaving modest headroom
    // for aspect-fill cropping and small quality losses during scaling.
    let targetHeight = destinationHeight * overscan
    let targetWidth = max(tileWidth, targetHeight * max(0.4, aspectRatio))

    return CGSize(width: ceil(targetWidth), height: ceil(targetHeight))
}

func generateTimelineThumbnailStripImage(
    fileURL: URL,
    visibleStartSeconds: Double,
    visibleEndSeconds: Double,
    totalDurationSeconds: Double,
    pixelWidth: Int,
    pixelHeight: Int,
    shouldCancel: @escaping @Sendable () -> Bool = { false }
) -> CGImage? {
    guard pixelWidth > 0, pixelHeight > 0, totalDurationSeconds > 0 else { return nil }

    let safeVisibleStart = max(0, min(visibleStartSeconds, totalDurationSeconds))
    let safeVisibleEnd = max(safeVisibleStart, min(visibleEndSeconds, totalDurationSeconds))
    let visibleDuration = max(0.001, safeVisibleEnd - safeVisibleStart)
    let asset = AVURLAsset(url: fileURL)
    let aspectRatio = estimatedVideoAspectRatio(for: asset)
    let preferredTileWidth = max(CGFloat(pixelHeight) * max(0.85, min(aspectRatio, 2.4)), 28)
    let baseTileCount = max(4, Int(round(CGFloat(pixelWidth) / preferredTileWidth)))
    let zoomRatio = max(1.0, totalDurationSeconds / visibleDuration)
    let zoomDensityBoost = min(1.18, max(1.0, pow(zoomRatio, 0.08)))
    let maxTileCountForComfort = max(4, Int(floor(CGFloat(pixelWidth) / max(20, preferredTileWidth * 0.88))))
    let tileCount = min(maxTileCountForComfort, max(4, Int(ceil(CGFloat(baseTileCount) * zoomDensityBoost))))
    let tileWidth = CGFloat(pixelWidth) / CGFloat(max(1, tileCount))
    let outputWidth = pixelWidth
    let toleranceSeconds = max(1.0 / 30.0, min(0.45, (visibleDuration / Double(tileCount)) * 0.35))
    let tolerance = CMTime(seconds: toleranceSeconds, preferredTimescale: 600)
    let decodeMaximumSize = thumbnailDecodeMaximumSize(
        aspectRatio: aspectRatio,
        tileWidth: tileWidth,
        pixelHeight: pixelHeight
    )
    let frameReuseBucketSeconds = max(
        1.0 / 24.0,
        min(0.5, (visibleDuration / Double(tileCount)) * 0.45)
    )
    let strictGenerator = makeThumbnailGenerator(
        asset: asset,
        maximumSize: decodeMaximumSize,
        tolerance: tolerance
    )
    let fallbackGenerator = makeThumbnailGenerator(
        asset: asset,
        maximumSize: decodeMaximumSize,
        tolerance: .positiveInfinity
    )

    defer {
        strictGenerator.cancelAllCGImageGeneration()
        fallbackGenerator.cancelAllCGImageGeneration()
    }

    let safeEndTime = max(0, totalDurationSeconds - (1.0 / 600.0))
    var images: [CGImage?] = Array(repeating: nil, count: tileCount)

    for index in 0..<tileCount {
        if shouldCancel() {
            return nil
        }

        let fraction = (Double(index) + 0.5) / Double(tileCount)
        let requestedSeconds = safeVisibleStart + (visibleDuration * fraction)
        let clampedSeconds = max(0, min(requestedSeconds, safeEndTime))
        let frameCacheKey = timelineThumbnailFrameCacheKey(
            for: fileURL,
            requestedSeconds: clampedSeconds,
            bucketSeconds: frameReuseBucketSeconds,
            decodeMaximumSize: decodeMaximumSize
        )

        if let cached = TimelineThumbnailFrameCache.image(forKey: frameCacheKey) {
            images[index] = cached
            continue
        }

        let requestTime = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        let image = copyThumbnailImage(
            strictGenerator: strictGenerator,
            fallbackGenerator: fallbackGenerator,
            time: requestTime
        )
        if let image {
            TimelineThumbnailFrameCache.insert(image, forKey: frameCacheKey)
        }
        images[index] = image
    }

    guard images.contains(where: { $0 != nil }) else { return nil }

    let bytesPerPixel = 4
    let bytesPerRow = outputWidth * bytesPerPixel
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard let context = CGContext(
        data: nil,
        width: outputWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        return nil
    }

    context.setFillColor(red: 0.07, green: 0.075, blue: 0.085, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: pixelHeight))

    for (index, image) in images.enumerated() {
        let minX = CGFloat(index) * tileWidth
        let maxX = index == tileCount - 1 ? CGFloat(outputWidth) : (CGFloat(index + 1) * tileWidth)
        let cellRect = CGRect(x: minX, y: 0, width: max(1, maxX - minX), height: CGFloat(pixelHeight))

        if let image {
            context.saveGState()
            context.clip(to: cellRect)
            context.draw(image, in: aspectFillRect(for: image, in: cellRect))
            context.restoreGState()
        }

        if index < (tileCount - 1) {
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.09)
            context.fill(CGRect(x: maxX - 1, y: 0, width: 1, height: CGFloat(pixelHeight)))
        }
    }

    let gradientColors = [
        CGColor(red: 0, green: 0, blue: 0, alpha: 0.16),
        CGColor(red: 0, green: 0, blue: 0, alpha: 0.0),
        CGColor(red: 0, green: 0, blue: 0, alpha: 0.18)
    ] as CFArray
    let locations: [CGFloat] = [0.0, 0.45, 1.0]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: locations) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(pixelHeight)),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }

    return context.makeImage()
}
