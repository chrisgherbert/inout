import Foundation

@MainActor
extension WorkspaceViewModel {
    func countSRTCues(at url: URL) -> Int {
        ToolDiscoveryUtilities.countSRTCues(at: url)
    }

    func runProcess(executableURL: URL, arguments: [String]) async -> String? {
        let commandLine = MediaToolUtilities.formatProcessCommand(executableURL: executableURL, arguments: arguments)
        let captureConsoleOutput = showActivityConsole
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout

            if captureConsoleOutput {
                Task { @MainActor [weak self] in
                    self?.appendActivityConsole("$ \(commandLine)", source: executableURL.lastPathComponent)
                }
            }

            let streamToConsole: (Data, String) -> Void = { data, source in
                guard captureConsoleOutput else { return }
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    Task { @MainActor [weak self] in
                        self?.appendActivityConsole(line, source: source)
                    }
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                streamToConsole(handle.availableData, "stdout")
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                streamToConsole(handle.availableData, "stderr")
            }

            do {
                try process.run()
                Task { @MainActor in
                    self.activeProcess = process
                }
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: error.localizedDescription)
                return
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    if self.activeProcess === proc {
                        self.activeProcess = nil
                    }
                }
                let trailingStdout = stdout.fileHandleForReading.readDataToEndOfFile()
                let trailingStderr = stderr.fileHandleForReading.readDataToEndOfFile()
                streamToConsole(trailingStdout, "stdout")
                streamToConsole(trailingStderr, "stderr")

                let errorText = String(decoding: trailingStderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else if errorText.isEmpty {
                    continuation.resume(returning: "\(executableURL.lastPathComponent) exited with status \(proc.terminationStatus)")
                } else {
                    continuation.resume(returning: errorText)
                }
            }
        }
    }

    func runWhisperProcessWithProgress(
        executableURL: URL,
        arguments: [String],
        statusPrefix: String,
        progressRange: ClosedRange<Double>
    ) async -> String? {
        let commandLine = MediaToolUtilities.formatProcessCommand(executableURL: executableURL, arguments: arguments)
        let captureConsoleOutput = showActivityConsole
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout

            if captureConsoleOutput {
                Task { @MainActor [weak self] in
                    self?.appendActivityConsole("$ \(commandLine)", source: "whisper")
                }
            }

            func emitProgress(_ progress: Double) {
                Task { @MainActor in
                    guard self.isExporting else { return }
                    let clamped = min(max(progress, 0), 1)
                    let mapped = progressRange.lowerBound + ((progressRange.upperBound - progressRange.lowerBound) * clamped)
                    self.exportProgress = min(max(mapped, 0), 1)
                    self.exportStatusText = "\(statusPrefix)… \(Int((clamped * 100).rounded()))%"
                }
            }

            let parseChunk: (Data, String) -> Void = { data, source in
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    if captureConsoleOutput {
                        Task { @MainActor [weak self] in
                            self?.appendActivityConsole(line, source: source)
                        }
                    }
                    if let progress = extractPercentProgress(from: line) {
                        emitProgress(progress)
                    }
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                parseChunk(handle.availableData, "whisper")
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                parseChunk(handle.availableData, "whisper")
            }

            do {
                try process.run()
                Task { @MainActor in
                    self.activeProcess = process
                }
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: error.localizedDescription)
                return
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    if self.activeProcess === proc {
                        self.activeProcess = nil
                    }
                }

                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                parseChunk(stdoutData, "whisper")
                parseChunk(stderrData, "whisper")

                let stderrText = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 {
                    emitProgress(1.0)
                    continuation.resume(returning: nil)
                } else if stderrText.isEmpty {
                    continuation.resume(returning: "\(executableURL.lastPathComponent) exited with status \(proc.terminationStatus)")
                } else {
                    continuation.resume(returning: stderrText)
                }
            }
        }
    }

    func runFFmpegProcessWithProgress(
        executableURL: URL,
        arguments: [String],
        durationSeconds: Double,
        statusPrefix: String,
        progressRange: ClosedRange<Double>? = nil
    ) async -> String? {
        let ffmpegArguments = arguments + ["-progress", "pipe:1", "-nostats"]
        let commandLine = MediaToolUtilities.formatProcessCommand(executableURL: executableURL, arguments: ffmpegArguments)
        let captureConsoleOutput = showActivityConsole
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ffmpegArguments

            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout

            let safeDuration = max(0.001, durationSeconds)
            var stdoutBuffer = Data()
            var stderrBuffer = Data()
            var stderrLines: [String] = []

            if captureConsoleOutput {
                Task { @MainActor [weak self] in
                    self?.appendActivityConsole("$ \(commandLine)", source: "ffmpeg")
                }
            }

            let emitProgress: (_ progress: Double, _ allowComplete: Bool) -> Void = { [weak self] progress, allowComplete in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isExporting else { return }
                    let clamped = min(max(progress, 0), 1)
                    let visualProgress = allowComplete ? clamped : min(clamped, 0.99)
                    if let range = progressRange {
                        let mapped = range.lowerBound + ((range.upperBound - range.lowerBound) * visualProgress)
                        self.exportProgress = min(max(mapped, 0), 1)
                    } else {
                        self.exportProgress = visualProgress
                    }
                    self.exportStatusText = "\(statusPrefix)… \(Int((visualProgress * 100).rounded()))%"
                }
            }

            let emitConsoleLine: (String, String) -> Void = { line, source in
                guard captureConsoleOutput else { return }
                Task { @MainActor [weak self] in
                    self?.appendActivityConsole(line, source: source)
                }
            }

            func consumeLines(buffer: inout Data, source: String, processLine: (String) -> Void) {
                while let separatorIndex = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineData = buffer.subdata(in: 0..<separatorIndex)
                    buffer.removeSubrange(0...separatorIndex)
                    guard let line = String(data: lineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          !line.isEmpty else { continue }
                    emitConsoleLine(line, source)
                    processLine(line)
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stdoutBuffer.append(chunk)
                consumeLines(buffer: &stdoutBuffer, source: "ffmpeg") { rawLine in
                    if rawLine == "progress=end" {
                        emitProgress(1.0, true)
                        return
                    }

                    if rawLine.hasPrefix("out_time_us="),
                       let microseconds = Double(rawLine.dropFirst("out_time_us=".count)) {
                        emitProgress((microseconds / 1_000_000.0) / safeDuration, false)
                        return
                    }

                    if rawLine.hasPrefix("out_time_ms="),
                       let value = Double(rawLine.dropFirst("out_time_ms=".count)) {
                        emitProgress((value / 1_000_000.0) / safeDuration, false)
                        return
                    }

                    if rawLine.hasPrefix("out_time="),
                       let seconds = parseTimecode(String(rawLine.dropFirst("out_time=".count))) {
                        emitProgress(seconds / safeDuration, false)
                    }
                }
            }

            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stderrBuffer.append(chunk)
                consumeLines(buffer: &stderrBuffer, source: "ffmpeg") { rawLine in
                    stderrLines.append(rawLine)
                }
            }

            do {
                try process.run()
                Task { @MainActor in
                    self.activeProcess = process
                }
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: error.localizedDescription)
                return
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    if self.activeProcess === proc {
                        self.activeProcess = nil
                    }
                }

                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                let trailingStdout = stdout.fileHandleForReading.readDataToEndOfFile()
                if !trailingStdout.isEmpty {
                    stdoutBuffer.append(trailingStdout)
                }
                if !stderrData.isEmpty {
                    stderrBuffer.append(stderrData)
                }

                consumeLines(buffer: &stdoutBuffer, source: "ffmpeg") { rawLine in
                    if rawLine == "progress=end" {
                        emitProgress(1.0, true)
                        return
                    }

                    if rawLine.hasPrefix("out_time_us="),
                       let microseconds = Double(rawLine.dropFirst("out_time_us=".count)) {
                        emitProgress((microseconds / 1_000_000.0) / safeDuration, false)
                        return
                    }

                    if rawLine.hasPrefix("out_time_ms="),
                       let value = Double(rawLine.dropFirst("out_time_ms=".count)) {
                        emitProgress((value / 1_000_000.0) / safeDuration, false)
                        return
                    }

                    if rawLine.hasPrefix("out_time="),
                       let seconds = parseTimecode(String(rawLine.dropFirst("out_time=".count))) {
                        emitProgress(seconds / safeDuration, false)
                    }
                }
                consumeLines(buffer: &stderrBuffer, source: "ffmpeg") { rawLine in
                    stderrLines.append(rawLine)
                }

                let stderrText = String(decoding: stderrData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stdoutText = String(decoding: stdoutBuffer, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stderrFromLines = stderrLines.suffix(8).joined(separator: "\n")

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else if !stderrText.isEmpty {
                    continuation.resume(returning: stderrText)
                } else if !stderrFromLines.isEmpty {
                    continuation.resume(returning: stderrFromLines)
                } else if !stdoutText.isEmpty {
                    continuation.resume(returning: stdoutText)
                } else {
                    continuation.resume(returning: "\(executableURL.lastPathComponent) exited with status \(proc.terminationStatus)")
                }
            }
        }
    }

    func runYTDLPProcessWithProgress(
        executableURL: URL,
        preArguments: [String],
        environment: [String: String],
        arguments: [String],
        statusPrefix: String,
        progressRange: ClosedRange<Double>
    ) async -> (downloadedPath: String?, error: String?) {
        let finalArguments = preArguments + arguments
        let commandLine = MediaToolUtilities.formatProcessCommand(executableURL: executableURL, arguments: finalArguments)
        let captureConsoleOutput = showActivityConsole
        return await withCheckedContinuation { (continuation: CheckedContinuation<(downloadedPath: String?, error: String?), Never>) in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = finalArguments
            if !environment.isEmpty {
                var merged = ProcessInfo.processInfo.environment
                for (key, value) in environment {
                    merged[key] = value
                }
                process.environment = merged
            }

            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout

            var stdoutBuffer = Data()
            var stderrBuffer = Data()
            var stderrLines: [String] = []
            var outputPath: String?

            func isYTDLPWarningLine(_ line: String) -> Bool {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let upper = trimmed.uppercased()
                return upper.hasPrefix("WARNING:") || upper.hasPrefix("[WARNING]")
            }

            if captureConsoleOutput {
                Task { @MainActor [weak self] in
                    self?.appendActivityConsole("$ \(commandLine)", source: "yt-dlp")
                }
            }

            let emitProgress: (Double) -> Void = { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isExporting else { return }
                    let clamped = min(max(progress, 0), 1)
                    let mapped = progressRange.lowerBound + ((progressRange.upperBound - progressRange.lowerBound) * clamped)
                    self.exportProgress = min(max(mapped, 0), 1)
                    self.exportStatusText = "\(statusPrefix)… \(Int((clamped * 100).rounded()))%"
                }
            }

            let emitConsoleLine: (String, String) -> Void = { line, source in
                guard captureConsoleOutput else { return }
                Task { @MainActor [weak self] in
                    self?.appendActivityConsole(line, source: source)
                }
            }

            let parseLine: (String) -> Void = { rawLine in
                if let progress = extractPercentProgress(from: rawLine) {
                    emitProgress(progress)
                }

                if rawLine.hasPrefix("after_move:") {
                    let path = String(rawLine.dropFirst("after_move:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty {
                        outputPath = path
                    }
                } else if rawLine.hasPrefix("/") {
                    let path = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if FileManager.default.fileExists(atPath: path) {
                        outputPath = path
                    }
                }
            }

            func consumeLines(buffer: inout Data, source: String) {
                while let separatorIndex = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineData = buffer.subdata(in: 0..<separatorIndex)
                    buffer.removeSubrange(0...separatorIndex)
                    guard let line = String(data: lineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          !line.isEmpty else { continue }
                    emitConsoleLine(line, source)
                    parseLine(line)
                    if source == "stderr" {
                        stderrLines.append(line)
                    }
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stdoutBuffer.append(chunk)
                consumeLines(buffer: &stdoutBuffer, source: "yt-dlp")
            }

            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stderrBuffer.append(chunk)
                consumeLines(buffer: &stderrBuffer, source: "stderr")
            }

            do {
                try process.run()
                Task { @MainActor in
                    self.activeProcess = process
                }
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (nil, error.localizedDescription))
                return
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    if self.activeProcess === proc {
                        self.activeProcess = nil
                    }
                }

                let trailingStdout = stdout.fileHandleForReading.readDataToEndOfFile()
                let trailingStderr = stderr.fileHandleForReading.readDataToEndOfFile()
                if !trailingStdout.isEmpty { stdoutBuffer.append(trailingStdout) }
                if !trailingStderr.isEmpty { stderrBuffer.append(trailingStderr) }
                consumeLines(buffer: &stdoutBuffer, source: "yt-dlp")
                consumeLines(buffer: &stderrBuffer, source: "stderr")

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: (outputPath, nil))
                } else {
                    let nonWarningLines = stderrLines.filter { !isYTDLPWarningLine($0) }

                    if nonWarningLines.isEmpty,
                       let outputPath,
                       FileManager.default.fileExists(atPath: outputPath) {
                        continuation.resume(returning: (outputPath, nil))
                        return
                    }

                    let stderrText = nonWarningLines.suffix(8).joined(separator: "\n")
                    if stderrText.isEmpty {
                        continuation.resume(returning: (nil, "yt-dlp exited with status \(proc.terminationStatus)"))
                    } else {
                        continuation.resume(returning: (nil, stderrText))
                    }
                }
            }
        }
    }

    func resolveYTDLPLaunch() -> YTDLPLaunchCommand? {
        downloaderManager.activeLaunchCommand()
    }
}
