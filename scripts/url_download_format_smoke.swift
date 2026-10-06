import Foundation

enum URLDownloadPreset: CaseIterable {
    case compatibleBest
    case compatible1080
    case compatible720
    case bestAnyToMP4
    case audioOnly
}

enum URLDownloadSaveLocationMode {
    case askEachTime
    case downloadsFolder
    case customFolder
}

enum URLDownloadAuthenticationMode {
    case none
    case browserCookies
}

enum URLDownloadBrowserCookiesSource {
    case safari

    var ytDLPArgument: String { "safari" }
}

enum MediaToolUtilities {
    static func uniqueUnderscoreIndexedURL(
        in directory: URL,
        preferredFileName: String,
        fileManager: FileManager
    ) -> URL {
        directory.appendingPathComponent(preferredFileName)
    }
}

@main
struct URLDownloadFormatSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fail("Usage: url-download-format-smoke /path/to/yt-dlp")
        }

        let ytDLPURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inout-ytdlp-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let fixtureURL = fixtureDirectory.appendingPathComponent("audio-only.json")
        try audioOnlyFixture.write(to: fixtureURL, atomically: true, encoding: .utf8)
        let videoFixtureURL = fixtureDirectory.appendingPathComponent("video.json")
        try videoFixture.write(to: videoFixtureURL, atomically: true, encoding: .utf8)

        for preset in URLDownloadPreset.allCases {
            let formatArguments = URLDownloadUtilities.ytDLPFormatArguments(for: preset)
            if [.compatibleBest, .compatible1080, .compatible720].contains(preset) {
                guard let selector = value(after: "-f", in: formatArguments),
                      selector.hasSuffix("/bestaudio/best") else {
                    fail("\(preset) does not include an audio-only fallback")
                }
            }

            let output = try selectedFormat(
                ytDLPURL: ytDLPURL,
                fixtureURL: fixtureURL,
                formatArguments: formatArguments
            )
            guard output.contains("vcodec=none"), output.contains("acodec=mp4a.40.2") else {
                fail("\(preset) did not select the audio-only fixture: \(output)")
            }

            let videoOutput = try selectedFormat(
                ytDLPURL: ytDLPURL,
                fixtureURL: videoFixtureURL,
                formatArguments: formatArguments
            )
            if preset == .audioOnly {
                guard videoOutput.contains("vcodec=none") else {
                    fail("Audio Only selected video data: \(videoOutput)")
                }
            } else {
                guard videoOutput.contains("vcodec=avc1.4d401f") else {
                    fail("\(preset) stopped preferring compatible video: \(videoOutput)")
                }
            }
        }

        print("URL download format smoke test passed (audio fallback and video preference verified).")
    }

    private static func selectedFormat(
        ytDLPURL: URL,
        fixtureURL: URL,
        formatArguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = ytDLPURL
        process.arguments = [
            "--ignore-config",
            "--no-warnings",
            "--load-info-json", fixtureURL.path,
            "--simulate"
        ] + formatArguments + [
            "--print", "vcodec=%(vcodec)s acodec=%(acodec)s ext=%(ext)s"
        ]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let outputText = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorText = String(
            data: error.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            fail("yt-dlp rejected an audio-only fixture: \(errorText)")
        }
        return outputText
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static let audioOnlyFixture = #"""
    {
      "id": "audio-only-fixture",
      "title": "Audio-only fixture",
      "extractor": "generic",
      "extractor_key": "Generic",
      "webpage_url": "https://example.invalid/audio",
      "formats": [
        {
          "format_id": "audio-m4a",
          "url": "https://example.invalid/audio.m4a",
          "ext": "m4a",
          "protocol": "https",
          "acodec": "mp4a.40.2",
          "vcodec": "none",
          "abr": 160,
          "tbr": 160,
          "filesize": 1000
        }
      ]
    }
    """#

    private static let videoFixture = #"""
    {
      "id": "video-fixture",
      "title": "Video fixture",
      "extractor": "generic",
      "extractor_key": "Generic",
      "webpage_url": "https://example.invalid/video",
      "formats": [
        {
          "format_id": "audio-m4a",
          "url": "https://example.invalid/audio.m4a",
          "ext": "m4a",
          "protocol": "https",
          "acodec": "mp4a.40.2",
          "vcodec": "none",
          "abr": 160,
          "tbr": 160,
          "filesize": 1000
        },
        {
          "format_id": "video-mp4",
          "url": "https://example.invalid/video.mp4",
          "ext": "mp4",
          "protocol": "https",
          "acodec": "none",
          "vcodec": "avc1.4d401f",
          "height": 720,
          "width": 1280,
          "fps": 30,
          "vbr": 2000,
          "tbr": 2000,
          "filesize": 10000
        }
      ]
    }
    """#

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("ERROR: \(message)\n").utf8))
        exit(1)
    }
}
