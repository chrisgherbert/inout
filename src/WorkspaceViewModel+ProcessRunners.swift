import Foundation
import InOutCore

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

private final class LockedBox<Value> {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    func snapshot() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class BufferedLineProcessor {
    private let buffer = LockedBox(Data())
    private let handleLine: @Sendable (String) -> Void

    init(handleLine: @escaping @Sendable (String) -> Void) {
        self.handleLine = handleLine
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.withValue { buffer in
            buffer.append(chunk)
            Self.consumeLines(from: &buffer, flushPartial: false, handleLine: handleLine)
        }
    }

    func finish(with trailingChunk: Data = Data()) {
        buffer.withValue { buffer in
            if !trailingChunk.isEmpty {
                buffer.append(trailingChunk)
            }
            Self.consumeLines(from: &buffer, flushPartial: true, handleLine: handleLine)
        }
    }

    private static func consumeLines(
        from buffer: inout Data,
        flushPartial: Bool,
        handleLine: @Sendable (String) -> Void
    ) {
        while let separatorIndex = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer.subdata(in: 0..<separatorIndex)
            buffer.removeSubrange(0...separatorIndex)
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { continue }
            handleLine(line)
        }

        guard flushPartial, !buffer.isEmpty else { return }
        let trailingData = buffer
        buffer.removeAll(keepingCapacity: true)
        guard let line = String(data: trailingData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty else { return }
        handleLine(line)
    }
}

private func isYTDLPWarningLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let upper = trimmed.uppercased()
    return upper.hasPrefix("WARNING:") || upper.hasPrefix("[WARNING]")
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
            let stderrLines = LockedBox<[String]>([])
            let stdoutProcessor = BufferedLineProcessor { line in
                consoleBatcher.enqueue(line: line, source: "stdout")
            }
            let stderrProcessor = BufferedLineProcessor { line in
                consoleBatcher.enqueue(line: line, source: "stderr")
                stderrLines.withValue { $0.append(line) }
            }

            if captureConsoleOutput {
                consoleBatcher.enqueue(line: "$ \(commandLine)", source: executableURL.lastPathComponent)
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                stdoutProcessor.append(handle.availableData)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                stderrProcessor.append(handle.availableData)
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
                stdoutProcessor.finish(with: trailingStdout)
                stderrProcessor.finish(with: trailingStderr)
                consoleBatcher.flushNow()

                let errorText = stderrLines.snapshot().joined(separator: "\n")
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
            let stderrLines = LockedBox<[String]>([])
            let stdoutProcessor = BufferedLineProcessor { line in
                if captureConsoleOutput {
                    consoleBatcher.enqueue(line: line, source: "whisper")
                }
                if let progress = extractPercentProgress(from: line) {
                    progressBatcher.enqueue(progress)
                }
            }
            let stderrProcessor = BufferedLineProcessor { line in
                if captureConsoleOutput {
                    consoleBatcher.enqueue(line: line, source: "whisper")
                }
                stderrLines.withValue { $0.append(line) }
                if let progress = extractPercentProgress(from: line) {
                    progressBatcher.enqueue(progress)
                }
            }

            if captureConsoleOutput {
                consoleBatcher.enqueue(line: "$ \(commandLine)", source: "whisper")
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                stdoutProcessor.append(handle.availableData)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                stderrProcessor.append(handle.availableData)
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
                stdoutProcessor.finish(with: stdoutData)
                stderrProcessor.finish(with: stderrData)
                consoleBatcher.flushNow()

                let stderrText = stderrLines.snapshot().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
            let stdoutLines = LockedBox<[String]>([])
            let stderrLines = LockedBox<[String]>([])

            if captureConsoleOutput {
                consoleBatcher.enqueue(line: "$ \(commandLine)", source: "ffmpeg")
            }

            let stdoutProcessor = BufferedLineProcessor { line in
                consoleBatcher.enqueue(line: line, source: "ffmpeg")
                stdoutLines.withValue { $0.append(line) }

                if line == "progress=end" {
                    progressBatcher.enqueue(1.0, immediate: true)
                    return
                }

                if line.hasPrefix("out_time_us="),
                   let microseconds = Double(line.dropFirst("out_time_us=".count)) {
                    progressBatcher.enqueue((microseconds / 1_000_000.0) / safeDuration)
                    return
                }

                if line.hasPrefix("out_time_ms="),
                   let value = Double(line.dropFirst("out_time_ms=".count)) {
                    progressBatcher.enqueue((value / 1_000_000.0) / safeDuration)
                    return
                }

                if line.hasPrefix("out_time="),
                   let seconds = parseTimecode(String(line.dropFirst("out_time=".count))) {
                    progressBatcher.enqueue(seconds / safeDuration)
                }
            }

            let stderrProcessor = BufferedLineProcessor { line in
                consoleBatcher.enqueue(line: line, source: "ffmpeg")
                stderrLines.withValue { $0.append(line) }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                stdoutProcessor.append(handle.availableData)
            }

            stderr.fileHandleForReading.readabilityHandler = { handle in
                stderrProcessor.append(handle.availableData)
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
                stdoutProcessor.finish(with: trailingStdout)
                stderrProcessor.finish(with: stderrData)
                consoleBatcher.flushNow()
                progressBatcher.flushNow()

                let stderrSnapshot = stderrLines.snapshot()
                let stdoutSnapshot = stdoutLines.snapshot()
                let stderrText = stderrSnapshot.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stdoutText = stdoutSnapshot.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stderrFromLines = stderrSnapshot.suffix(8).joined(separator: "\n")

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

            let stderrLines = LockedBox<[String]>([])
            let outputPath = LockedBox<String?>(nil)

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
                        outputPath.withValue { $0 = path }
                    }
                } else if rawLine.hasPrefix("/") {
                    let path = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if FileManager.default.fileExists(atPath: path) {
                        outputPath.withValue { $0 = path }
                    }
                }
            }

            let stdoutProcessor = BufferedLineProcessor { line in
                consoleBatcher.enqueue(line: line, source: "yt-dlp")
                parseLine(line)
            }

            let stderrProcessor = BufferedLineProcessor { line in
                consoleBatcher.enqueue(line: line, source: "stderr")
                parseLine(line)
                stderrLines.withValue { $0.append(line) }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                stdoutProcessor.append(handle.availableData)
            }

            stderr.fileHandleForReading.readabilityHandler = { handle in
                stderrProcessor.append(handle.availableData)
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
                stdoutProcessor.finish(with: trailingStdout)
                stderrProcessor.finish(with: trailingStderr)
                consoleBatcher.flushNow()
                progressBatcher.flushNow()

                let resolvedOutputPath = outputPath.snapshot()
                let stderrSnapshot = stderrLines.snapshot()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: (resolvedOutputPath, nil))
                } else {
                    let nonWarningLines = stderrSnapshot.filter { !isYTDLPWarningLine($0) }

                    if nonWarningLines.isEmpty,
                       let resolvedOutputPath,
                       FileManager.default.fileExists(atPath: resolvedOutputPath) {
                        continuation.resume(returning: (resolvedOutputPath, nil))
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
