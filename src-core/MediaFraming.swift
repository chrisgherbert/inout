import Foundation

public enum MediaFramingAspectRatio: String, CaseIterable, Identifiable, Sendable {
    case original = "Original"
    case widescreen = "16:9"
    case vertical = "9:16"
    case square = "1:1"
    case portrait = "4:5"

    public var id: String { rawValue }

    public var ratio: Double? {
        switch self {
        case .original: return nil
        case .widescreen: return 16.0 / 9.0
        case .vertical: return 9.0 / 16.0
        case .square: return 1.0
        case .portrait: return 4.0 / 5.0
        }
    }
}

public enum MediaFramingMode: String, CaseIterable, Identifiable, Sendable {
    case fit = "Fit Entire Image"
    case fill = "Crop to Fill"
    case blurredBackground = "Blurred Background"

    public var id: String { rawValue }

    public var shortLabel: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .blurredBackground: return "Blur"
        }
    }

    public var detail: String {
        switch self {
        case .fit: return "Keep the complete picture and add black space."
        case .fill: return "Fill the frame by cropping its edges."
        case .blurredBackground: return "Keep the picture over a blurred copy."
        }
    }
}

public enum MediaFramingCropAlignment: String, CaseIterable, Identifiable, Sendable {
    case center = "Center"
    case top = "Top"
    case bottom = "Bottom"
    case left = "Left"
    case right = "Right"

    public var id: String { rawValue }
}

public struct MediaFramingDimensions: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public func parsedMediaResolution(_ resolution: String?) -> MediaFramingDimensions? {
    guard let resolution else { return nil }
    let numbers = resolution
        .components(separatedBy: CharacterSet.decimalDigits.inverted)
        .compactMap(Int.init)
    guard numbers.count >= 2, numbers[0] > 0, numbers[1] > 0 else { return nil }
    return MediaFramingDimensions(width: numbers[0], height: numbers[1])
}

public func mediaFramingAspectRatioMatchesSource(
    _ aspectRatio: MediaFramingAspectRatio,
    source: MediaFramingDimensions,
    relativeTolerance: Double = 0.005
) -> Bool {
    guard let targetRatio = aspectRatio.ratio, source.height > 0 else { return false }
    let sourceRatio = Double(source.width) / Double(source.height)
    return abs(sourceRatio - targetRatio) / targetRatio <= max(0, relativeTolerance)
}

public func mediaFramingAvailableAspectRatios(
    for source: MediaFramingDimensions?
) -> [MediaFramingAspectRatio] {
    MediaFramingAspectRatio.allCases.filter { aspectRatio in
        aspectRatio == .original || source.map {
            !mediaFramingAspectRatioMatchesSource(aspectRatio, source: $0)
        } ?? true
    }
}

public func mediaFramingOutputDimensions(
    aspectRatio: MediaFramingAspectRatio,
    source: MediaFramingDimensions,
    maximumShortEdge: Int?
) -> MediaFramingDimensions? {
    guard let ratio = aspectRatio.ratio else { return nil }
    let sourceShortEdge = min(source.width, source.height)
    let shortEdge = max(2, min(sourceShortEdge, maximumShortEdge ?? sourceShortEdge))

    let width: Int
    let height: Int
    if ratio >= 1 {
        height = evenDimension(shortEdge)
        width = evenDimension(Int((Double(height) * ratio).rounded()))
    } else {
        width = evenDimension(shortEdge)
        height = evenDimension(Int((Double(width) / ratio).rounded()))
    }
    return MediaFramingDimensions(width: width, height: height)
}

public func mediaFramingVideoFilter(
    aspectRatio: MediaFramingAspectRatio,
    mode: MediaFramingMode,
    cropAlignment: MediaFramingCropAlignment,
    source: MediaFramingDimensions,
    maximumShortEdge: Int?
) -> String? {
    guard let output = mediaFramingOutputDimensions(
        aspectRatio: aspectRatio,
        source: source,
        maximumShortEdge: maximumShortEdge
    ) else { return nil }

    let width = output.width
    let height = output.height
    switch mode {
    case .fit:
        return "scale=\(width):\(height):force_original_aspect_ratio=decrease:force_divisible_by=2,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1"
    case .fill:
        let position = cropPosition(for: cropAlignment)
        return "scale=\(width):\(height):force_original_aspect_ratio=increase,crop=\(width):\(height):\(position.x):\(position.y),setsar=1"
    case .blurredBackground:
        return "split=2[framing_bg][framing_fg];" +
            "[framing_bg]scale=\(width):\(height):force_original_aspect_ratio=increase," +
            "crop=\(width):\(height),boxblur=20:2[framing_bg_ready];" +
            "[framing_fg]scale=\(width):\(height):force_original_aspect_ratio=decrease:force_divisible_by=2[framing_fg_ready];" +
            "[framing_bg_ready][framing_fg_ready]overlay=(W-w)/2:(H-h)/2,setsar=1"
    }
}

private func evenDimension(_ value: Int) -> Int {
    let safe = max(2, value)
    return safe.isMultiple(of: 2) ? safe : safe - 1
}

private func cropPosition(for alignment: MediaFramingCropAlignment) -> (x: String, y: String) {
    switch alignment {
    case .center: return ("(in_w-out_w)/2", "(in_h-out_h)/2")
    case .top: return ("(in_w-out_w)/2", "0")
    case .bottom: return ("(in_w-out_w)/2", "in_h-out_h")
    case .left: return ("0", "(in_h-out_h)/2")
    case .right: return ("in_w-out_w", "(in_h-out_h)/2")
    }
}
