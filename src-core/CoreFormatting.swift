import Foundation

public enum TimecodeDisplayLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case clock
    case adaptiveClock
    case totalMinutes
    case totalSeconds
    case frameNumber

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .clock: return "Hours, Minutes, Seconds"
        case .adaptiveClock: return "Short Time"
        case .totalMinutes: return "Total Minutes, Seconds"
        case .totalSeconds: return "Total Seconds"
        case .frameNumber: return "Absolute Frame Number"
        }
    }
}

public enum TimecodeDisplayPrecision: String, Codable, CaseIterable, Identifiable, Sendable {
    case seconds
    case milliseconds
    case frames

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .seconds: return "Whole Seconds"
        case .milliseconds: return "Milliseconds"
        case .frames: return "Frames"
        }
    }
}

public enum TimecodeSeparator: String, Codable, CaseIterable, Identifiable, Sendable {
    case colon = ":"
    case period = "."
    case hyphen = "-"
    case comma = ","

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .colon: return "Colon (:)"
        case .period: return "Period (.)"
        case .hyphen: return "Hyphen (-)"
        case .comma: return "Comma (,)"
        }
    }
}

public struct TimecodeFormatConfiguration: Codable, Equatable, Hashable, Sendable {
    public var layout: TimecodeDisplayLayout
    public var precision: TimecodeDisplayPrecision
    public var timeSeparator: TimecodeSeparator
    public var subsecondSeparator: TimecodeSeparator
    public var padsFirstComponent: Bool

    public init(
        layout: TimecodeDisplayLayout,
        precision: TimecodeDisplayPrecision,
        timeSeparator: TimecodeSeparator = .colon,
        subsecondSeparator: TimecodeSeparator = .period,
        padsFirstComponent: Bool = true
    ) {
        self.layout = layout
        self.precision = layout == .frameNumber ? .frames : precision
        self.timeSeparator = timeSeparator
        self.subsecondSeparator = subsecondSeparator
        self.padsFirstComponent = padsFirstComponent
    }

    public var normalized: TimecodeFormatConfiguration {
        var result = self
        if result.layout == .frameNumber {
            result.precision = .frames
            result.padsFirstComponent = false
        }
        return result
    }

    public var notation: String {
        let separator = timeSeparator.rawValue
        let base: String
        switch layout {
        case .clock:
            base = "HH\(separator)MM\(separator)SS"
        case .adaptiveClock:
            let short = "M\(separator)SS"
            let long = "H\(separator)MM\(separator)SS"
            base = "\(short) / \(long)"
        case .totalMinutes:
            base = "MM\(separator)SS"
        case .totalSeconds:
            base = "SS"
        case .frameNumber:
            return "Frames"
        }

        switch precision {
        case .seconds:
            return base
        case .milliseconds:
            return base
                .split(separator: " ", omittingEmptySubsequences: false)
                .map { $0.hasSuffix("SS") ? "\($0)\(subsecondSeparator.rawValue)mmm" : String($0) }
                .joined(separator: " ")
        case .frames:
            return base
                .split(separator: " ", omittingEmptySubsequences: false)
                .map { $0.hasSuffix("SS") ? "\($0)\(subsecondSeparator.rawValue)FF" : String($0) }
                .joined(separator: " ")
        }
    }

    public var example: String {
        formatDisplayTimecode(83.5, format: self, frameRate: 24)
    }
}

public enum TimecodeDisplayStyle: String, CaseIterable, Identifiable, Codable, Sendable {
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

    public var format: TimecodeFormatConfiguration {
        switch self {
        case .precise:
            return TimecodeFormatConfiguration(layout: .clock, precision: .milliseconds)
        case .standard:
            return TimecodeFormatConfiguration(layout: .clock, precision: .seconds)
        case .compact:
            return TimecodeFormatConfiguration(
                layout: .adaptiveClock,
                precision: .seconds,
                padsFirstComponent: false
            )
        case .frames:
            return TimecodeFormatConfiguration(
                layout: .clock,
                precision: .frames,
                subsecondSeparator: .colon
            )
        case .minuteFrames:
            return TimecodeFormatConfiguration(
                layout: .totalMinutes,
                precision: .frames,
                subsecondSeparator: .colon
            )
        case .periodFrames:
            return TimecodeFormatConfiguration(layout: .clock, precision: .frames)
        case .minutePeriodFrames:
            return TimecodeFormatConfiguration(layout: .totalMinutes, precision: .frames)
        case .totalSeconds:
            return TimecodeFormatConfiguration(
                layout: .totalSeconds,
                precision: .milliseconds,
                padsFirstComponent: false
            )
        case .frameNumber:
            return TimecodeFormatConfiguration(
                layout: .frameNumber,
                precision: .frames,
                padsFirstComponent: false
            )
        }
    }

    public var notation: String { format.notation }
    public var example: String { format.example }
    public var menuTitle: String { "\(title) (\(notation))" }
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
    formatDisplayTimecode(value, format: style.format, frameRate: frameRate)
}

public func formatDisplayTimecode(
    _ value: Double,
    format requestedFormat: TimecodeFormatConfiguration,
    frameRate: Double? = nil
) -> String {
    let safe = max(0, value.isFinite ? value : 0)
    let format = requestedFormat.normalized

    if format.layout == .frameNumber {
        guard let nominalFrameRate = nominalFrameRate(frameRate) else {
            return formatDisplayTimecode(safe, style: .precise)
        }
        return String(Int(floor(safe * nominalFrameRate)))
    }

    let wholeSeconds: Int
    let subsecondText: String?
    switch format.precision {
    case .seconds:
        wholeSeconds = Int(floor(safe))
        subsecondText = nil
    case .milliseconds:
        let totalMilliseconds = Int((safe * 1_000).rounded())
        wholeSeconds = totalMilliseconds / 1_000
        subsecondText = String(format: "%03d", totalMilliseconds % 1_000)
    case .frames:
        guard let nominalFrameRate = nominalFrameRate(frameRate) else {
            return formatDisplayTimecode(safe, style: .precise)
        }
        wholeSeconds = Int(floor(safe))
        let frame = min(
            Int(nominalFrameRate) - 1,
            Int(floor((safe - floor(safe)) * nominalFrameRate))
        )
        subsecondText = String(format: "%02d", frame)
    }

    if format.layout == .totalSeconds {
        let base = firstComponent(wholeSeconds, padded: format.padsFirstComponent)
        guard let subsecondText else { return base }
        return base + format.subsecondSeparator.rawValue + subsecondText
    }

    let separator = format.timeSeparator.rawValue
    let base: String
    switch format.layout {
    case .clock:
        base = [
            firstComponent(wholeSeconds / 3_600, padded: format.padsFirstComponent),
            String(format: "%02d", (wholeSeconds / 60) % 60),
            String(format: "%02d", wholeSeconds % 60)
        ].joined(separator: separator)
    case .adaptiveClock:
        let hours = wholeSeconds / 3_600
        if hours > 0 {
            base = [
                firstComponent(hours, padded: format.padsFirstComponent),
                String(format: "%02d", (wholeSeconds / 60) % 60),
                String(format: "%02d", wholeSeconds % 60)
            ].joined(separator: separator)
        } else {
            base = [
                firstComponent(wholeSeconds / 60, padded: format.padsFirstComponent),
                String(format: "%02d", wholeSeconds % 60)
            ].joined(separator: separator)
        }
    case .totalMinutes:
        base = [
            firstComponent(wholeSeconds / 60, padded: format.padsFirstComponent),
            String(format: "%02d", wholeSeconds % 60)
        ].joined(separator: separator)
    case .totalSeconds, .frameNumber:
        preconditionFailure("Handled before component formatting")
    }

    guard let subsecondText else { return base }
    return base + format.subsecondSeparator.rawValue + subsecondText
}

public func parseTimecode(
    _ value: String,
    format: TimecodeFormatConfiguration,
    frameRate: Double? = nil
) -> Double? {
    let format = format.normalized
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if format.layout == .frameNumber {
        guard let nominalFrameRate = nominalFrameRate(frameRate),
              let frame = nonnegativeInteger(trimmed) else { return nil }
        return Double(frame) / nominalFrameRate
    }

    let mainText: String
    let fraction: Double
    switch format.precision {
    case .seconds:
        mainText = trimmed
        fraction = 0
    case .milliseconds, .frames:
        guard let split = splitSubsecond(from: trimmed, format: format),
              let subsecond = nonnegativeInteger(split.subsecond) else { return nil }
        mainText = split.main
        if format.precision == .milliseconds {
            guard subsecond < 1_000 else { return nil }
            fraction = Double(subsecond) / 1_000.0
        } else {
            guard let nominalFrameRate = nominalFrameRate(frameRate),
                  Double(subsecond) < nominalFrameRate else { return nil }
            fraction = Double(subsecond) / nominalFrameRate
        }
    }

    let parts = mainText.components(separatedBy: format.timeSeparator.rawValue)
    let wholeSeconds: Double
    switch format.layout {
    case .clock:
        guard parts.count == 3,
              let hours = nonnegativeInteger(parts[0]),
              let minutes = boundedTimeComponent(parts[1]),
              let seconds = boundedTimeComponent(parts[2]) else { return nil }
        wholeSeconds = Double((hours * 3_600) + (minutes * 60) + seconds)
    case .adaptiveClock:
        if parts.count == 2,
           let minutes = nonnegativeInteger(parts[0]),
           let seconds = boundedTimeComponent(parts[1]) {
            wholeSeconds = Double((minutes * 60) + seconds)
        } else if parts.count == 3,
                  let hours = nonnegativeInteger(parts[0]),
                  let minutes = boundedTimeComponent(parts[1]),
                  let seconds = boundedTimeComponent(parts[2]) {
            wholeSeconds = Double((hours * 3_600) + (minutes * 60) + seconds)
        } else {
            return nil
        }
    case .totalMinutes:
        guard parts.count == 2,
              let minutes = nonnegativeInteger(parts[0]),
              let seconds = boundedTimeComponent(parts[1]) else { return nil }
        wholeSeconds = Double((minutes * 60) + seconds)
    case .totalSeconds:
        guard parts.count == 1,
              let seconds = nonnegativeInteger(parts[0]) else { return nil }
        wholeSeconds = Double(seconds)
    case .frameNumber:
        return nil
    }
    return wholeSeconds + fraction
}

public func parseTimecode(
    _ value: String,
    style: TimecodeDisplayStyle? = nil,
    frameRate: Double? = nil
) -> Double? {
    if let style {
        return parseTimecode(value, format: style.format, frameRate: frameRate)
    }

    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: ".")
    let parts = normalized.split(separator: ":")
    guard !parts.isEmpty && parts.count <= 4 else { return nil }
    let numbers = parts.compactMap { Double($0) }
    guard numbers.count == parts.count else { return nil }
    switch numbers.count {
    case 1: return numbers[0]
    case 2: return (numbers[0] * 60) + numbers[1]
    case 3: return (numbers[0] * 3_600) + (numbers[1] * 60) + numbers[2]
    case 4:
        guard let nominalFrameRate = nominalFrameRate(frameRate),
              numbers[3] >= 0, numbers[3] < nominalFrameRate,
              numbers[3].rounded(.towardZero) == numbers[3] else { return nil }
        return (numbers[0] * 3_600) + (numbers[1] * 60) + numbers[2] + (numbers[3] / nominalFrameRate)
    default: return nil
    }
}

private func nominalFrameRate(_ frameRate: Double?) -> Double? {
    guard let frameRate, frameRate.isFinite, frameRate > 0 else { return nil }
    return Double(max(1, Int(frameRate.rounded())))
}

private func firstComponent(_ value: Int, padded: Bool) -> String {
    padded ? String(format: "%02d", value) : String(value)
}

private func nonnegativeInteger(_ value: String) -> Int? {
    guard let parsed = Int(value), parsed >= 0 else { return nil }
    return parsed
}

private func boundedTimeComponent(_ value: String) -> Int? {
    guard let parsed = nonnegativeInteger(value), parsed < 60 else { return nil }
    return parsed
}

private func splitSubsecond(
    from value: String,
    format: TimecodeFormatConfiguration
) -> (main: String, subsecond: String)? {
    let separator = format.subsecondSeparator.rawValue
    guard let range = value.range(of: separator, options: .backwards) else { return nil }
    let main = String(value[..<range.lowerBound])
    let subsecond = String(value[range.upperBound...])
    guard !main.isEmpty, !subsecond.isEmpty else { return nil }
    return (main, subsecond)
}
