import FluidAudio
import Foundation

private struct Output: Codable {
    let audioFile: String
    let modelVersion: String
    let text: String
    let durationSeconds: TimeInterval
    let processingTimeSeconds: TimeInterval
    let rtfx: Float
    let confidence: Float
    let tokenTimings: [TokenTiming]
}

private func usage() -> Never {
    FileHandle.standardError.write(Data("""
    Usage: parakeet-transcriber <audio.wav> --output-json <path> [--model-dir <path>] [--model-version v2|v3]

    """.utf8))
    Foundation.exit(2)
}

private func parseArgs() -> (
    audioPath: String,
    outputJSON: String,
    modelDirectory: String?,
    version: AsrModelVersion,
    versionLabel: String
) {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let audioPath = args.first, !audioPath.hasPrefix("-") else {
        usage()
    }

    var outputJSON: String?
    var modelDirectory: String?
    var version: AsrModelVersion = .v2
    var versionLabel = "v2"
    var index = 1

    while index < args.count {
        switch args[index] {
        case "--output-json":
            guard index + 1 < args.count else { usage() }
            outputJSON = args[index + 1]
            index += 2
        case "--model-dir":
            guard index + 1 < args.count else { usage() }
            modelDirectory = args[index + 1]
            index += 2
        case "--model-version":
            guard index + 1 < args.count else { usage() }
            switch args[index + 1].lowercased() {
            case "v2", "2":
                version = .v2
                versionLabel = "v2"
            case "v3", "3":
                version = .v3
                versionLabel = "v3"
            default:
                usage()
            }
            index += 2
        default:
            usage()
        }
    }

    guard let outputJSON else { usage() }
    return (audioPath, outputJSON, modelDirectory, version, versionLabel)
}

@main
struct ParakeetTranscriber {
    static func main() async {
        let parsed = parseArgs()
        let outputURL = URL(fileURLWithPath: parsed.outputJSON)

        do {
            let models: AsrModels
            if let modelDirectory = parsed.modelDirectory {
                models = try await AsrModels.load(
                    from: URL(fileURLWithPath: modelDirectory),
                    version: parsed.version,
                    encoderPrecision: .int8
                )
            } else {
                models = try await AsrModels.downloadAndLoad(
                    version: parsed.version,
                    encoderPrecision: .int8
                )
            }

            let asrConfig = ASRConfig(
                tdtConfig: TdtConfig(blankId: parsed.version.blankId),
                encoderHiddenSize: parsed.version.encoderHiddenSize
            )
            let asrManager = AsrManager(config: asrConfig)
            try await asrManager.loadModels(models)

            var decoderState = try TdtDecoderState(decoderLayers: parsed.version.decoderLayers)
            let samples = try AudioConverter().resampleAudioFile(path: parsed.audioPath)
            let start = Date()
            let result = try await asrManager.transcribe(samples, decoderState: &decoderState)
            let measuredProcessingTime = Date().timeIntervalSince(start)
            let processingTime = result.processingTime > 0 ? result.processingTime : measuredProcessingTime
            let duration = result.duration
            let rtfx = processingTime > 0 ? Float(duration / processingTime) : 0

            let output = Output(
                audioFile: parsed.audioPath,
                modelVersion: parsed.versionLabel,
                text: result.text,
                durationSeconds: duration,
                processingTimeSeconds: processingTime,
                rtfx: rtfx,
                confidence: result.confidence,
                tokenTimings: result.tokenTimings ?? []
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(output).write(to: outputURL)
            print(result.text)
        } catch {
            FileHandle.standardError.write(Data("Parakeet transcription failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
