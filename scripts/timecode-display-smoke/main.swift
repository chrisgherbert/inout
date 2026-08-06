import Foundation

private func expect(_ actual: String, _ expected: String, _ label: String) {
    guard actual == expected else {
        fputs("\(label): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

private func expectClose(_ actual: Double?, _ expected: Double, _ label: String) {
    guard let actual, abs(actual - expected) < 0.000_001 else {
        fputs("\(label): expected \(expected), got \(String(describing: actual))\n", stderr)
        exit(1)
    }
}

expect(TimecodeDisplayStyle.precise.menuTitle, "Hours:Minutes:Seconds.Milliseconds (HH:MM:SS.mmm)", "precise label")
expect(TimecodeDisplayStyle.standard.menuTitle, "Hours:Minutes:Seconds (HH:MM:SS)", "whole-second label")
expect(TimecodeDisplayStyle.compact.menuTitle, "Minutes:Seconds or Hours:Minutes:Seconds (M:SS / H:MM:SS)", "short-form label")
expect(TimecodeDisplayStyle.frames.menuTitle, "Hours:Minutes:Seconds:Frames (HH:MM:SS:FF)", "hour frame label")
expect(TimecodeDisplayStyle.minuteFrames.menuTitle, "Minutes:Seconds:Frames (MM:SS:FF)", "minute frame label")
expect(TimecodeDisplayStyle.periodFrames.menuTitle, "Hours:Minutes:Seconds.Frames (HH:MM:SS.FF)", "period hour frame label")
expect(TimecodeDisplayStyle.minutePeriodFrames.menuTitle, "Minutes:Seconds.Frames (MM:SS.FF)", "period minute frame label")
expect(TimecodeDisplayStyle.totalSeconds.menuTitle, "Total Seconds.Milliseconds (SS.mmm)", "total seconds label")
expect(TimecodeDisplayStyle.frameNumber.menuTitle, "Absolute Frame Number (Frames)", "frame number label")

expect(formatDisplayTimecode(83.456, style: .precise), "00:01:23.456", "precise")
expect(formatDisplayTimecode(59.9996, style: .precise), "00:01:00.000", "precise rollover")
expect(formatDisplayTimecode(83.999, style: .standard), "00:01:23", "standard")
expect(formatDisplayTimecode(83.999, style: .compact), "1:23", "compact")
expect(formatDisplayTimecode(3_723, style: .compact), "1:02:03", "compact hours")
expect(formatDisplayTimecode(83.5, style: .frames, frameRate: 24), "00:01:23:12", "frames")
expect(formatDisplayTimecode(83.5, style: .frames), "00:01:23.500", "frames fallback")
expect(formatDisplayTimecode(83.5, style: .minuteFrames, frameRate: 24), "01:23:12", "minute frames")
expect(formatDisplayTimecode(3_723.5, style: .minuteFrames, frameRate: 24), "62:03:12", "minute frames over one hour")
expect(formatDisplayTimecode(83.5, style: .minuteFrames), "00:01:23.500", "minute frames fallback")
expect(formatDisplayTimecode(83.5, style: .periodFrames, frameRate: 24), "00:01:23.12", "period frames")
expect(formatDisplayTimecode(3_723.5, style: .minutePeriodFrames, frameRate: 24), "62:03.12", "period minute frames")
expect(formatDisplayTimecode(83.456, style: .totalSeconds), "83.456", "total seconds")
expect(formatDisplayTimecode(83.5, style: .frameNumber, frameRate: 24), "2004", "frame number")
expect(formatDisplayTimecode(83.5, style: .frameNumber), "00:01:23.500", "frame number fallback")

expectClose(parseTimecode("01:02:03.500"), 3_723.5, "precise parse")
expectClose(parseTimecode("1:23"), 83, "compact parse")
expectClose(parseTimecode("00:01:23:12", frameRate: 24), 83.5, "frame parse")
expectClose(parseTimecode("01:23:12", style: .minuteFrames, frameRate: 24), 83.5, "minute frame parse")
expectClose(parseTimecode("62:03:12", style: .minuteFrames, frameRate: 24), 3_723.5, "minute frame parse over one hour")
expectClose(parseTimecode("00:01:23.12", style: .periodFrames, frameRate: 24), 83.5, "period frame parse")
expectClose(parseTimecode("62:03.12", style: .minutePeriodFrames, frameRate: 24), 3_723.5, "period minute frame parse")
expectClose(parseTimecode("83.456", style: .totalSeconds), 83.456, "total seconds parse")
expectClose(parseTimecode("2004", style: .frameNumber, frameRate: 24), 83.5, "frame number parse")
guard parseTimecode("00:01:23:24", frameRate: 24) == nil else {
    fputs("invalid frame parse: expected nil\n", stderr)
    exit(1)
}
guard parseTimecode("01:23:24", style: .minuteFrames, frameRate: 24) == nil else {
    fputs("invalid minute frame parse: expected nil\n", stderr)
    exit(1)
}
guard parseTimecode("00:01:23.24", style: .periodFrames, frameRate: 24) == nil else {
    fputs("invalid period frame parse: expected nil\n", stderr)
    exit(1)
}
guard parseTimecode("01:23.24", style: .minutePeriodFrames, frameRate: 24) == nil else {
    fputs("invalid period minute frame parse: expected nil\n", stderr)
    exit(1)
}

print("Timecode display smoke test passed.")
