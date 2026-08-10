import Foundation
import InOutCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("Media framing smoke test failed: \(message)\n", stderr)
        exit(1)
    }
}

func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (-1, error.localizedDescription)
    }
    let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (process.terminationStatus, output + error)
}

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: media-framing-smoke <ffmpeg> <ffprobe>\n", stderr)
    exit(2)
}

let ffmpeg = CommandLine.arguments[1]
let ffprobe = CommandLine.arguments[2]
let source = MediaFramingDimensions(width: 640, height: 360)

require(parsedMediaResolution("1920 × 1080") == MediaFramingDimensions(width: 1920, height: 1080), "resolution parsing failed")
let widescreenOptions = mediaFramingAvailableAspectRatios(for: MediaFramingDimensions(width: 1920, height: 1080))
require(!widescreenOptions.contains(.widescreen), "16:9 should be hidden for a 16:9 source")
require(widescreenOptions.contains(.vertical), "unmatched aspect ratios should remain available")
let portraitOptions = mediaFramingAvailableAspectRatios(for: MediaFramingDimensions(width: 1080, height: 1350))
require(!portraitOptions.contains(.portrait), "4:5 should be hidden for a 4:5 source")
require(mediaFramingAvailableAspectRatios(for: nil) == MediaFramingAspectRatio.allCases, "unknown source dimensions should keep all options")
require(mediaFramingOutputDimensions(aspectRatio: .original, source: source, maximumShortEdge: nil) == nil, "Original should not force dimensions")
require(mediaFramingOutputDimensions(aspectRatio: .widescreen, source: source, maximumShortEdge: nil) == source, "16:9 dimensions changed unexpectedly")
require(mediaFramingOutputDimensions(aspectRatio: .vertical, source: source, maximumShortEdge: nil) == MediaFramingDimensions(width: 360, height: 640), "9:16 dimensions are incorrect")
require(mediaFramingOutputDimensions(aspectRatio: .square, source: source, maximumShortEdge: 720) == MediaFramingDimensions(width: 360, height: 360), "square dimensions are incorrect")
require(mediaFramingOutputDimensions(aspectRatio: .portrait, source: MediaFramingDimensions(width: 3840, height: 2160), maximumShortEdge: 1080) == MediaFramingDimensions(width: 1080, height: 1350), "4:5 1080p dimensions are incorrect")

let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("inout-media-framing-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempDirectory) }

let cases: [(MediaFramingAspectRatio, MediaFramingMode, MediaFramingCropAlignment)] = [
    (.widescreen, .fit, .center),
    (.vertical, .fit, .center),
    (.vertical, .fill, .left),
    (.vertical, .fill, .right),
    (.vertical, .blurredBackground, .center),
    (.square, .fit, .center),
    (.portrait, .fill, .top)
]

for (index, testCase) in cases.enumerated() {
    let (aspectRatio, mode, cropAlignment) = testCase
    guard let dimensions = mediaFramingOutputDimensions(
        aspectRatio: aspectRatio,
        source: source,
        maximumShortEdge: nil
    ), let filter = mediaFramingVideoFilter(
        aspectRatio: aspectRatio,
        mode: mode,
        cropAlignment: cropAlignment,
        source: source,
        maximumShortEdge: nil
    ) else {
        require(false, "missing filter for \(aspectRatio.rawValue) \(mode.rawValue)")
        continue
    }

    let outputURL = tempDirectory.appendingPathComponent("case-\(index).png")
    let render = run(ffmpeg, [
        "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=1",
        "-frames:v", "1", "-vf", filter, outputURL.path
    ])
    require(render.status == 0, "FFmpeg rejected \(aspectRatio.rawValue) \(mode.rawValue): \(render.output)")

    let probe = run(ffprobe, [
        "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x",
        outputURL.path
    ])
    require(probe.status == 0, "ffprobe failed: \(probe.output)")
    let actual = probe.output.trimmingCharacters(in: .whitespacesAndNewlines)
    require(actual == "\(dimensions.width)x\(dimensions.height)", "expected \(dimensions.width)x\(dimensions.height), got \(actual)")
}

let customCropFilter = mediaFramingVideoFilter(
    aspectRatio: .vertical,
    mode: .fill,
    cropAlignment: .custom,
    customCropX: 0.25,
    customCropY: 0.75,
    source: source,
    maximumShortEdge: nil
) ?? ""
require(customCropFilter.contains("(in_w-out_w)*0.250000"), "custom horizontal crop was not encoded")
require(customCropFilter.contains("(in_h-out_h)*0.750000"), "custom vertical crop was not encoded")
let clampedCropFilter = mediaFramingVideoFilter(
    aspectRatio: .vertical,
    mode: .fill,
    cropAlignment: .custom,
    customCropX: -2,
    customCropY: 3,
    source: source,
    maximumShortEdge: nil
) ?? ""
require(clampedCropFilter.contains("(in_w-out_w)*0.000000"), "custom horizontal crop was not clamped")
require(clampedCropFilter.contains("(in_h-out_h)*1.000000"), "custom vertical crop was not clamped")
let customCropURL = tempDirectory.appendingPathComponent("custom-crop.png")
let customCropRender = run(ffmpeg, [
    "-y", "-hide_banner", "-loglevel", "error",
    "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=1",
    "-frames:v", "1", "-vf", customCropFilter, customCropURL.path
])
require(customCropRender.status == 0, "FFmpeg rejected custom crop coordinates: \(customCropRender.output)")
let customCropProbe = run(ffprobe, [
    "-v", "error", "-select_streams", "v:0",
    "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x",
    customCropURL.path
])
require(customCropProbe.output.trimmingCharacters(in: .whitespacesAndNewlines) == "360x640", "custom crop dimensions are incorrect")
let leftCropData = try Data(contentsOf: tempDirectory.appendingPathComponent("case-2.png"))
let rightCropData = try Data(contentsOf: tempDirectory.appendingPathComponent("case-3.png"))
let customCropData = try Data(contentsOf: customCropURL)
require(leftCropData != rightCropData, "left and right crop presets rendered the same frame")
require(customCropData != leftCropData && customCropData != rightCropData, "custom crop did not produce a distinct frame")

let combinedOutputURL = tempDirectory.appendingPathComponent("blur-with-audio.mp4")
let combinedFilter = mediaFramingVideoFilter(
    aspectRatio: .vertical,
    mode: .blurredBackground,
    cropAlignment: .center,
    source: source,
    maximumShortEdge: nil
) ?? ""
let combinedRender = run(ffmpeg, [
    "-y", "-hide_banner", "-loglevel", "error",
    "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24",
    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
    "-t", "0.25",
    "-map", "0:v:0",
    "-filter_complex", "[1:a:0]volume=0.8[aout]", "-map", "[aout]",
    "-vf", combinedFilter,
    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
    combinedOutputURL.path
])
require(combinedRender.status == 0, "blurred framing failed alongside audio filters: \(combinedRender.output)")
let combinedProbe = run(ffprobe, [
    "-v", "error", "-show_entries", "stream=codec_type,width,height",
    "-of", "csv=p=0", combinedOutputURL.path
])
require(combinedProbe.status == 0, "combined export probe failed: \(combinedProbe.output)")
require(combinedProbe.output.contains("video,360,640"), "combined export video dimensions are incorrect")
require(combinedProbe.output.contains("audio"), "combined export lost its audio stream")

let topCrop = mediaFramingVideoFilter(
    aspectRatio: .vertical,
    mode: .fill,
    cropAlignment: .top,
    source: source,
    maximumShortEdge: nil
) ?? ""
require(topCrop.contains(":0,setsar=1"), "top crop alignment was not encoded")

print("Media framing smoke test passed (\(cases.count + 2) FFmpeg renders).")
