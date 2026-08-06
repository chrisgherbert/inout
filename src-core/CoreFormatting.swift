import Foundation

public enum TimecodeDisplayStyle: String, CaseIterable, Identifiable {
    case precise
    case standard
    case compact
    case frames
    case minuteFrames
    case periodFrames
    case minutePeriodFrames
    case totalSeconds
    case frameNumber

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .precise: return "Hours:Minutes:Seconds.Milliseconds"
        case .standard: return "Hours:Minutes:Seconds"
        case .compact: return "Minutes:Seconds or Hours:Minutes:Seconds"
        case .frames: return "Hours:Minutes:Seconds:Frames"
        case .minuteFrames: return "Minutes:Seconds:Frames"
        case .periodFrames: return "Hours:Minutes:Seconds.Frames"
        case .minutePeriodFrames: return "Minutes:Seconds.Frames"
        case .totalSeconds: return "Total Seconds.Milliseconds"
        case .frameNumber: return "Absolute Frame Number"
        }
    }

    public var notation: String {
        switch self {
        case .precise: return "HH:MM:SS.mmm"
        case .standard: return "HH:MM:SS"
        case .compact: return "M:SS / H:MM:SS"
        case .frames: return "HH:MM:SS:FF"
        case .minuteFrames: return "MM:SS:FF"
        case .periodFrames: return "HH:MM:SS.FF"
        case .minutePeriodFrames: return "MM:SS.FF"
        case .totalSeconds: return "SS.mmm"
        case .frameNumber: return "Frames"
        }
    }

    public var example: String {
        switch self {
        case .precise: return "00:01:23.456"
        case .standard: return "00:01:23"
        case .compact: return "1:23"
        case .frames: return "00:01:23:11"
        case .minuteFrames: return "01:23:11"
        case .periodFrames: return "00:01:23.11"
        case .minutePeriodFrames: return "01:23.11"
        case .totalSeconds: return "83.456"
        case .frameNumber: return "2003"
        }
    }

    public var menuTitle: String {
        "\(title) (\(notation))"
    }
}

public func formatSeconds(_ value: Double) -> String {
    let whole = Int(value)
    let h = whole / 3600
    let m = (whole % 3600) / 60
    let s = whole % 60
    let ms = Int(((value - floor(value)) * 1000.0).rounded())
    return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
}

public func formatDisplayTimecode(
    _ value: Double,
    style: TimecodeDisplayStyle,
    frameRate: Double? = nil
) -> String {
    let safe = max(0, value.isFinite ? value : 0)

    switch style {
    case .precise:
        let totalMilliseconds = Int((safe * 1_000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let seconds = (totalMilliseconds / 1_000) % 60
        let milliseconds = totalMilliseconds % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    case .standard:
        let wholeSeconds = Int(floor(safe))
        return String(
            format: "%02d:%02d:%02d",
            wholeSeconds / 3_600,
            (wholeSeconds / 60) % 60,
            wholeSeconds % 60
        )
    case .compact:
        let wholeSeconds = Int(floor(safe))
        let hours = wholeSeconds / 3_600
        let minutes = (wholeSeconds / 60) % 60
        let seconds = wholeSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", wholeSeconds / 60, seconds)
    case .totalSeconds:
        let totalMilliseconds = Int((safe * 1_000).rounded())
        return String(
            format: "%d.%03d",
            totalMilliseconds / 1_000,
            totalMilliseconds % 1_000
        )
    case .frames, .minuteFrames, .periodFrames, .minutePeriodFrames, .frameNumber:
        guard let frameRate, frameRate.isFinite, frameRate > 0 else {
            return formatDisplayTimecode(safe, style: .precise)
        }
        let nominalFrameRate = max(1, Int(frameRate.rounded()))
        let wholeSeconds = Int(floor(safe))
        let frame = min(
            nominalFrameRate - 1,
            Int(floor((safe - floor(safe)) * Double(nominalFrameRate)))
        )
        switch style {
        case .frames:
            return String(
                format: "%02d:%02d:%02d:%02d",
                wholeSeconds / 3_600,
                (wholeSeconds / 60) % 60,
                wholeSeconds % 60,
                frame
            )
        case .minuteFrames:
            return String(
                format: "%02d:%02d:%02d",
                wholeSeconds / 60,
                wholeSeconds % 60,
                frame
            )
        case .periodFrames:
            return String(
                format: "%02d:%02d:%02d.%02d",
                wholeSeconds / 3_600,
                (wholeSeconds / 60) % 60,
                wholeSeconds % 60,
                frame
            )
        case .minutePeriodFrames:
            return String(
                format: "%02d:%02d.%02d",
                wholeSeconds / 60,
                wholeSeconds % 60,
                frame
            )
        case .frameNumber:
            return String(Int(floor(safe * Double(nominalFrameRate))))
        default:
            preconditionFailure("Unexpected frame timecode style")
        }
    }
}

public func parseTimecode(
    _ value: String,
    style: TimecodeDisplayStyle? = nil,
    frameRate: Double? = nil
) -> Double? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let parts = trimmed.split(separator: ":")
    guard !parts.isEmpty && parts.count <= 4 else { return nil }

    func parseSeconds(_ token: Substring) -> Double? {
        Double(token.replacingOccurrences(of: ",", with: "."))
    }

    func nominalFrameRate() -> Double? {
        guard let frameRate, frameRate.isFinite, frameRate > 0 else { return nil }
        return Double(max(1, Int(frameRate.rounded())))
    }

    func parseSecondAndFrame(_ token: Substring) -> (seconds: Double, frame: Double)? {
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              let seconds = Double(components[0]),
              let frame = Double(components[1]),
              seconds >= 0, seconds < 60,
              frame >= 0, frame.rounded(.towardZero) == frame else { return nil }
        return (seconds, frame)
    }

    if style == .frameNumber {
        guard parts.count == 1,
              let nominalFrameRate = nominalFrameRate(),
              let frame = Double(parts[0]),
              frame >= 0,
              frame.rounded(.towardZero) == frame else { return nil }
        return frame / nominalFrameRate
    }

    if style == .periodFrames {
        guard parts.count == 3,
              let nominalFrameRate = nominalFrameRate(),
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let time = parseSecondAndFrame(parts[2]),
              hours >= 0,
              minutes >= 0, minutes < 60,
              time.frame < nominalFrameRate else { return nil }
        return (hours * 3_600.0) + (minutes * 60.0) + time.seconds + (time.frame / nominalFrameRate)
    }

    if style == .minutePeriodFrames {
        guard parts.count == 2,
              let nominalFrameRate = nominalFrameRate(),
              let minutes = Double(parts[0]),
              let time = parseSecondAndFrame(parts[1]),
              minutes >= 0,
              time.frame < nominalFrameRate else { return nil }
        return (minutes * 60.0) + time.seconds + (time.frame / nominalFrameRate)
    }

    switch parts.count {
    case 1:
        return parseSeconds(parts[0])
    case 2:
        guard let minutes = Double(parts[0]), let seconds = parseSeconds(parts[1]) else { return nil }
        return (minutes * 60.0) + seconds
    case 3:
        if style == .minuteFrames {
            guard let nominalFrameRate = nominalFrameRate(),
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]),
                  let frame = Double(parts[2]) else { return nil }
            guard seconds >= 0, seconds < 60,
                  frame >= 0, frame < nominalFrameRate,
                  frame.rounded(.towardZero) == frame else { return nil }
            return (minutes * 60.0) + seconds + (frame / nominalFrameRate)
        }
        guard let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = parseSeconds(parts[2]) else { return nil }
        return (hours * 3_600.0) + (minutes * 60.0) + seconds
    case 4:
        guard let nominalFrameRate = nominalFrameRate(),
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]),
              let frame = Double(parts[3]) else { return nil }
        guard frame >= 0, frame < nominalFrameRate,
              frame.rounded(.towardZero) == frame else { return nil }
        return (hours * 3_600.0) + (minutes * 60.0) + seconds + (frame / nominalFrameRate)
    default:
        return nil
    }
}
