import Foundation

private final class ConsoleLineBatcher {
    private let isEnabled: Bool
    private let flushInterval: TimeInterval
    private let sink: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "inout.process.console-batcher")
    private var pendingChunk = ""
    private var flushScheduled = false

    init(
        isEnabled: Bool,
        flushInterval: TimeInterval = 0.1,
        sink: @escaping @Sendable (String) -> Void
    ) {
        self.isEnabled = isEnabled
        self.flushInterval = flushInterval
        self.sink = sink
    }

    func enqueue(line: String, source: String) {
        guard isEnabled else { return }
        let cleaned = line.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let rendered = source.isEmpty ? cleaned : "[\(source)] \(cleaned)"
        queue.async {
            if self.pendingChunk.isEmpty {
                self.pendingChunk = rendered
            } else {
                self.pendingChunk += "\n" + rendered
            }

            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            self.queue.asyncAfter(deadline: .now() + self.flushInterval) {
                self.flushLocked()
            }
        }
    }

    func flushNow() {
        guard isEnabled else { return }
        let chunk = queue.sync {
            let chunk = pendingChunk
            pendingChunk = ""
            flushScheduled = false
            return chunk
        }
        guard !chunk.isEmpty else { return }
        sink(chunk)
    }

    private func flushLocked() {
        let chunk = pendingChunk
        pendingChunk = ""
        flushScheduled = false
        guard !chunk.isEmpty else { return }
        sink(chunk)
    }
}

private final class ProgressUpdateBatcher {
    private let flushInterval: TimeInterval
    private let sink: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "inout.process.progress-batcher")
    private var latestProgress: Double?
    private var flushScheduled = false

    init(flushInterval: TimeInterval = 0.08, sink: @escaping @Sendable (Double) -> Void) {
        self.flushInterval = flushInterval
        self.sink = sink
    }

    func enqueue(_ progress: Double, immediate: Bool = false) {
        queue.async {
            self.latestProgress = progress
            if immediate {
                self.flushLocked()
                return
            }

            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            self.queue.asyncAfter(deadline: .now() + self.flushInterval) {
                self.flushLocked()
            }
        }
    }

    func flushNow() {
        let progress = queue.sync {
            let progress = latestProgress
            latestProgress = nil
            flushScheduled = false
            return progress
        }
        guard let progress else { return }
        sink(progress)
    }

    private func flushLocked() {
        let progress = latestProgress
        latestProgress = nil
        flushScheduled = false
        guard let progress else { return }
        sink(progress)
    }
}

@MainActor
extension WorkspaceViewModel {
    func countSRTCues(at url: URL) -> Int {
        ToolDiscoveryUtilities.countSRTCues(at: url)
    }

    func runProcess(executableURL: URL, arguments: [String]) async -> String? {
        let commandLine = MediaToolUtilities.formatProcessCommand(executableURL: executableURL, arguments: arguments)
        let captureConsoleOutput = showActivityConsole
        let consoleBatcher = ConsoleLineBatcher(isEnabled: captureConsoleOutput) { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.appendActivityConsoleChunk(chunk)
            }
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout

            if captureConsoleOutput {
                consoleBatcher.enqueue(line: "$ \(commandLine)", source: executableURL.lastPathComponent)
            }

            let streamToConsole: (Data, String) -> Void = { data, source in
                guard captureConsoleOutput else { return }
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    consoleBatcher.enqueue(line: line, source: source)
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
                consoleBatcher.flushNow()

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
        let consoleBatcher = ConsoleLineBatcher(isEnabled: captureConsoleOutput) { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.appendActivityConsoleChunk(chunk)
            }
        }
        let progressBatcher = ProgressUpdateBatcher { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                guard self.isExporting else { return }
                let clamped = min(max(progress, 0), 1)
                let mapped = progressRange.lowerBound + ((progressRange.upperBound - progressRange.lowerBound) * clamped)
                self.exportProgress = min(max(mapped, 0), 1)
                self.exportStatusText = "\(statusPrefix)… \(Int((clamped * 100).rounded()))%"
            }
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stderr = Pipe()
            let stdout = Pipe()
            process.standardError = stderr
            process.standardOutput = stdout

            if captureConsoleOutput {
                consoleBatcher.enqueue(line: "$ \(commandLine)", source: "whisper")
            }

            let parseChunk: (Data, String) -> Void = { data, source in
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    if captureConsoleOutput {
                        consoleBatcher.enqueue(line: line, source: source)
                    }
                    if let progress = extractPercentProgress(from: line) {
                        progressBatcher.enqueue(progress)
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
                consoleBatcher.flushNow()

                let stderrText = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 {
                    progressBatcher.enqueue(1.0, immediate: true)
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
        let consoleBatcher = ConsoleLineBatcher(isEnabled: captureConsoleOutput) { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.appendActivityConsoleChunk(chunk)
            }
        }
        let progressBatcher = ProgressUpdateBatcher { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                guard self.isExporting else { return }
                let clamped = min(max(progress, 0), 1)
                let visualProgress = min(clamped, 0.99)
                if let range = progressRange {
                    let mapped = range.lowerBound + ((range.upperBound - range.lowerBound) * visualProgress)
                    self.exportProgress = min(max(mapped, 0), 1)
                } else {
                    self.exportProgress = visualProgress
                }
                self.exportStatusText = "\(statusPrefix)… \(Int((visualProgress * 100).rounded()))%"
            }
        }
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
                consoleBatcher.enqueue(line: "$ \(commandLine)", source: "ffmpeg")
            }

            func consumeLines(buffer: inout Data, source: String, processLine: (String) -> Void) {
                while let separatorIndex = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineData = buffer.subdata(in: 0..<separatorIndex)
                    buffer.removeSubrange(0...separatorIndex)
                    guard let line = String(data: lineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          !line.isEmpty else { continue }
                    consoleBatcher.enqueue(line: line, source: source)
                    processLine(line)
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stdoutBuffer.append(chunk)
                consumeLines(buffer: &stdoutBuffer, source: "ffmpeg") { rawLine in
                    if rawLine == "progress=end" {
                        progressBatcher.enqueue(1.0, immediate: true)
                        return
                    }

                    if rawLine.hasPrefix("out_time_us="),
                       let microseconds = Double(rawLine.dropFirst("out_time_us=".count)) {
                        progressBatcher.enqueue((microseconds / 1_000_000.0) / safeDuration)
                        return
                    }

                    if rawLine.hasPrefix("out_time_ms="),
                       let value = Double(rawLine.dropFirst("out_time_ms=".count)) {
                        progressBatcher.enqueue((value / 1_000_000.0) / safeDuration)
                        return
                    }

                    if rawLine.hasPrefix("out_time="),
                       let seconds = parseTimecode(String(rawLine.dropFirst("out_time=".count))) {
                        progressBatcher.enqueue(seconds / safeDuration)
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
                        progressBatcher.enqueue(1.0, immediate: true)
                        return
                    }

                    if rawLine.hasPrefix("out_time_us="),
                       let microseconds = Double(rawLine.dropFirst("out_time_us=".count)) {
                        progressBatcher.enqueue((microseconds / 1_000_000.0) / safeDuration)
                        return
                    }

                    if rawLine.hasPrefix("out_time_ms="),
                       let value = Double(rawLine.dropFirst("out_time_ms=".count)) {
                        progressBatcher.enqueue((value / 1_000_000.0) / safeDuration)
                        return
                    }

                    if rawLine.hasPrefix("out_time="),
                       let seconds = parseTimecode(String(rawLine.dropFirst("out_time=".count))) {
                        progressBatcher.enqueue(seconds / safeDuration)
                    }
                }
                consumeLines(buffer: &stderrBuffer, source: "ffmpeg") { rawLine in
                    stderrLines.append(rawLine)
                }
                consoleBatcher.flushNow()
                progressBatcher.flushNow()

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
        let consoleBatcher = ConsoleLineBatcher(isEnabled: captureConsoleOutput) { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.appendActivityConsoleChunk(chunk)
            }
        }
        let progressBatcher = ProgressUpdateBatcher { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                guard self.isExporting else { return }
                let clamped = min(max(progress, 0), 1)
                let mapped = progressRange.lowerBound + ((progressRange.upperBound - progressRange.lowerBound) * clamped)
                self.exportProgress = min(max(mapped, 0), 1)
                self.exportStatusText = "\(statusPrefix)… \(Int((clamped * 100).rounded()))%"
            }
        }
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
                consoleBatcher.enqueue(line: "$ \(commandLine)", source: "yt-dlp")
            }

            let parseLine: (String) -> Void = { rawLine in
                if let progress = extractPercentProgress(from: rawLine) {
                    progressBatcher.enqueue(progress)
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
                    consoleBatcher.enqueue(line: line, source: source)
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
                consoleBatcher.flushNow()
                progressBatcher.flushNow()

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
