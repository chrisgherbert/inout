import Foundation
import AVFoundation

public func normalizedToken(_ token: String) -> String {
    token
        .trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines))
        .lowercased()
}

public func profanityWordsFromString(_ raw: String) -> Set<String> {
    let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
    return Set(
        raw.components(separatedBy: separators)
            .map(normalizedToken)
            .filter { !$0.isEmpty }
    )
}

public func normalizedProfanityWordsStorageString(_ raw: String) -> String {
    profanityWordsFromString(raw).sorted().joined(separator: ", ")
}

public func sanitizeFilenameComponent(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
    let sanitizedScalars = value.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) }
    let sanitized = String(sanitizedScalars)
        .replacingOccurrences(of: "\n", with: "_")
        .replacingOccurrences(of: "\r", with: "_")
    return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
}

public func extractPercentProgress(from line: String) -> Double? {
    let pattern = #"([0-9]{1,3})(?:\.[0-9]+)?\s*%"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    guard let match = regex.firstMatch(in: line, range: range),
          let percentRange = Range(match.range(at: 1), in: line),
          let percent = Double(line[percentRange]) else { return nil }
    return min(max(percent / 100.0, 0.0), 1.0)
}

public func findWhisperExecutable() -> URL? {
    if let bundled = Bundle.main.url(forResource: "whisper-cli", withExtension: nil),
       FileManager.default.isExecutableFile(atPath: bundled.path) {
        return bundled
    }
    return nil
}

public func findWhisperModel() -> URL? {
    if let bundled = Bundle.main.url(forResource: "profanity-model", withExtension: "bin"),
       FileManager.default.fileExists(atPath: bundled.path) {
        return bundled
    }
    return nil
}

public func findParakeetTranscriberExecutable() -> URL? {
    if let bundled = Bundle.main.url(forResource: "parakeet-transcriber", withExtension: nil),
       FileManager.default.isExecutableFile(atPath: bundled.path) {
        return bundled
    }
    return nil
}

public func findParakeetModelDirectory() -> URL? {
    if let bundled = Bundle.main.url(forResource: "parakeet-tdt-0.6b-v2", withExtension: nil),
       FileManager.default.fileExists(atPath: bundled.path) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundled.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return bundled
    }
    return nil
}

private func findSystemFFmpegExecutable() -> URL? {
    if let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil),
       FileManager.default.isExecutableFile(atPath: bundled.path) {
        return bundled
    }

    var candidates = ["/usr/bin/ffmpeg"]
    if let path = ProcessInfo.processInfo.environment["PATH"] {
        for entry in path.split(separator: ":") {
            candidates.append(String(entry) + "/ffmpeg")
        }
    }

    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
        return URL(fileURLWithPath: candidate)
    }
    return nil
}

private struct ParakeetTranscriptionOutput: Decodable {
    let text: String
    let tokenTimings: [ParakeetTokenTiming]
}

private struct ParakeetTokenTiming: Decodable {
    let token: String
    let startTime: Double
    let endTime: Double
}

private struct ParakeetWordTiming {
    let word: String
    let startTime: Double
    let endTime: Double
}

private struct ParakeetProgressUpdate {
    let progress: Double
    let phase: String?
}

private func parseParakeetProgressLine(_ line: String) -> ParakeetProgressUpdate? {
    let pattern = #"^PARAKEET_PROGRESS\s+([0-9]*\.?[0-9]+)(?:\s+(.+))?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    guard let match = regex.firstMatch(in: line, range: range),
          let valueRange = Range(match.range(at: 1), in: line),
          let value = Double(line[valueRange]) else {
        return nil
    }
    let phase: String?
    if match.range(at: 2).location != NSNotFound,
       let phaseRange = Range(match.range(at: 2), in: line) {
        let trimmedPhase = line[phaseRange].trimmingCharacters(in: .whitespacesAndNewlines)
        phase = trimmedPhase.isEmpty ? nil : trimmedPhase
    } else {
        phase = nil
    }
    return ParakeetProgressUpdate(progress: min(max(value, 0.0), 1.0), phase: phase)
}

private func runSynchronousProcess(
    executableURL: URL,
    arguments: [String],
    shouldCancel: @escaping @Sendable () -> Bool,
    source: String,
    onOutputLine: @escaping @Sendable (String, String) -> Void = { _, _ in }
) -> Result<(stdout: String, stderr: String), DetectionError> {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    onOutputLine("$ \(executableURL.path) " + arguments.joined(separator: " "), source)

    var stdoutData = Data()
    var stderrData = Data()
    let lock = NSLock()

    func emitLines(_ data: Data, sourceTag: String) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                onOutputLine(line, sourceTag)
            }
        }
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock()
        stdoutData.append(chunk)
        lock.unlock()
        emitLines(chunk, sourceTag: source)
    }

    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock()
        stderrData.append(chunk)
        lock.unlock()
        emitLines(chunk, sourceTag: source)
    }

    do {
        try process.run()
    } catch {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return .failure(.failed("Failed to run \(executableURL.lastPathComponent): \(error.localizedDescription)"))
    }

    while process.isRunning {
        if shouldCancel() {
            process.terminate()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(.cancelled)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    lock.lock()
    let trailingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let trailingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    stdoutData.append(trailingStdout)
    stderrData.append(trailingStderr)
    let stdout = String(decoding: stdoutData, as: UTF8.self)
    let stderr = String(decoding: stderrData, as: UTF8.self)
    lock.unlock()
    emitLines(trailingStdout, sourceTag: source)
    emitLines(trailingStderr, sourceTag: source)

    if process.terminationStatus == 0 {
        return .success((stdout: stdout, stderr: stderr))
    }

    let errorText = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if errorText.isEmpty {
        return .failure(.failed("\(executableURL.lastPathComponent) exited with status \(process.terminationStatus)"))
    }
    return .failure(.failed(errorText))
}

private func runSynchronousProcessWithProgress(
    executableURL: URL,
    arguments: [String],
    shouldCancel: @escaping @Sendable () -> Bool,
    progressHandler: @escaping @Sendable (Double) -> Void,
    source: String,
    onOutputLine: @escaping @Sendable (String, String) -> Void = { _, _ in }
) -> Result<(stdout: String, stderr: String), DetectionError> {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    onOutputLine("$ \(executableURL.path) " + arguments.joined(separator: " "), source)

    var stdoutData = Data()
    var stderrData = Data()
    let lock = NSLock()

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        if let text = String(data: data, encoding: .utf8) {
            for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                onOutputLine(line, source)
                if let progress = extractPercentProgress(from: line) {
                    progressHandler(progress)
                }
            }
        }
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock()
        stdoutData.append(chunk)
        lock.unlock()
        consume(chunk)
    }

    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock()
        stderrData.append(chunk)
        lock.unlock()
        consume(chunk)
    }

    do {
        try process.run()
    } catch {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return .failure(.failed("Failed to run \(executableURL.lastPathComponent): \(error.localizedDescription)"))
    }

    while process.isRunning {
        if shouldCancel() {
            process.terminate()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(.cancelled)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    lock.lock()
    let trailingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let trailingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    stdoutData.append(trailingStdout)
    stderrData.append(trailingStderr)
    let stdout = String(decoding: stdoutData, as: UTF8.self)
    let stderr = String(decoding: stderrData, as: UTF8.self)
    lock.unlock()

    if process.terminationStatus == 0 {
        progressHandler(1.0)
        return .success((stdout: stdout, stderr: stderr))
    }

    let errorText = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if errorText.isEmpty {
        return .failure(.failed("\(executableURL.lastPathComponent) exited with status \(process.terminationStatus)"))
    }
    return .failure(.failed(errorText))
}

private func parseTranscriptionSegments(_ jsonData: Data) -> [TranscriptSegment] {
    guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        return []
    }

    var segmentsOut: [TranscriptSegment] = []
    let transcription = object["transcription"] as? [[String: Any]] ?? object["segments"] as? [[String: Any]] ?? []
    for segment in transcription {
        let text = (segment["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }

        let startMs: Double? = ((segment["offsets"] as? [String: Any])?["from"] as? Double)
        let endMs: Double? = ((segment["offsets"] as? [String: Any])?["to"] as? Double)
        let startSecAlt = segment["start"] as? Double
        let endSecAlt = segment["end"] as? Double

        let start = max(0, (startMs ?? (startSecAlt ?? 0)) / (startMs != nil ? 1000.0 : 1.0))
        let endRaw = (endMs ?? (endSecAlt ?? (start + 0.2))) / (endMs != nil ? 1000.0 : 1.0)
        let end = max(start + 0.05, endRaw)
        segmentsOut.append(TranscriptSegment(start: start, end: end, text: text))
    }

    segmentsOut.sort { lhs, rhs in
        if abs(lhs.start - rhs.start) > 0.0001 { return lhs.start < rhs.start }
        return lhs.text < rhs.text
    }
    return segmentsOut
}

private func parseStreamingTranscriptTimestamp(_ raw: String) -> Double? {
    let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = cleaned.split(separator: ":")
    guard parts.count == 3,
          let hours = Double(parts[0]),
          let minutes = Double(parts[1]),
          let seconds = Double(parts[2]) else {
        return nil
    }
    return (hours * 3600.0) + (minutes * 60.0) + seconds
}

private func parseStreamingTranscriptSegment(from line: String) -> TranscriptSegment? {
    let pattern = #"^\s*\[?(\d{2}:\d{2}:\d{2}(?:[.,]\d+)?)\s*-->\s*(\d{2}:\d{2}:\d{2}(?:[.,]\d+)?)\]?\s*(.+?)\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    guard let match = regex.firstMatch(in: line, range: range),
          let startRange = Range(match.range(at: 1), in: line),
          let endRange = Range(match.range(at: 2), in: line),
          let textRange = Range(match.range(at: 3), in: line) else {
        return nil
    }

    let startText = line[startRange].replacingOccurrences(of: ",", with: ".")
    let endText = line[endRange].replacingOccurrences(of: ",", with: ".")
    let text = line[textRange].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty,
          let start = parseStreamingTranscriptTimestamp(String(startText)),
          let end = parseStreamingTranscriptTimestamp(String(endText)) else {
        return nil
    }

    return TranscriptSegment(
        start: max(0, start),
        end: max(start + 0.05, end),
        text: text
    )
}

private func normalizedParakeetTranscriptText(_ text: String) -> String {
    var result = text.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: #"\s+([,.;:!?])"#,
        with: "$1",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: #"([^0-9]),(?=[0-9])"#,
        with: "$1, ",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: #"\(\s+"#,
        with: "(",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: #"\s+\)"#,
        with: ")",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: #"([a-z])([0-9])"#,
        with: "$1 $2",
        options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: #"([0-9])([A-Z][a-z])"#,
        with: "$1 $2",
        options: .regularExpression
    )
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func parakeetTextHasSegmentBoundary(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = trimmed.last else { return false }
    return ".!?".contains(last)
}

private func parakeetTextHasClauseBoundary(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = trimmed.last else { return false }
    return ",;:".contains(last)
}

private func parakeetTokenStartsWord(_ token: String) -> Bool {
    token.hasPrefix(" ") || token.hasPrefix("▁")
}

private func parakeetTokenWithoutWordBoundary(_ token: String) -> String {
    if token.hasPrefix(" ") || token.hasPrefix("▁") {
        return String(token.dropFirst())
    }
    return token
}

private func makeParakeetWordTimings(from tokens: [ParakeetTokenTiming], fallbackText: String) -> [ParakeetWordTiming] {
    let sortedTokens = tokens
        .filter { !$0.token.isEmpty && $0.endTime >= $0.startTime }
        .sorted {
            if abs($0.startTime - $1.startTime) > 0.0001 { return $0.startTime < $1.startTime }
            return $0.endTime < $1.endTime
        }
    let fallbackWords = normalizedParakeetTranscriptText(fallbackText)
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
        .filter { !$0.isEmpty }

    guard !sortedTokens.isEmpty else {
        guard !fallbackWords.isEmpty else { return [] }
        return fallbackWords.enumerated().map { index, word in
            ParakeetWordTiming(
                word: word,
                startTime: Double(index) * 0.05,
                endTime: Double(index + 1) * 0.05
            )
        }
    }

    var words: [ParakeetWordTiming] = []
    var currentWord = ""
    var currentStart = max(0, sortedTokens[0].startTime)
    var currentEnd = max(currentStart + 0.05, sortedTokens[0].endTime)

    func flushWord() {
        let word = normalizedParakeetTranscriptText(currentWord)
        guard !word.isEmpty else {
            currentWord = ""
            return
        }
        words.append(
            ParakeetWordTiming(
                word: word,
                startTime: max(0, currentStart),
                endTime: max(currentStart + 0.05, currentEnd)
            )
        )
        currentWord = ""
    }

    for token in sortedTokens {
        let startsWord = parakeetTokenStartsWord(token.token)
        let tokenText = startsWord ? parakeetTokenWithoutWordBoundary(token.token) : token.token
        if startsWord && tokenText.isEmpty {
            flushWord()
            continue
        }
        guard !tokenText.isEmpty else { continue }
        let tokenStart = max(0, token.startTime)
        let tokenEnd = max(tokenStart + 0.05, token.endTime)

        if startsWord && !currentWord.isEmpty {
            flushWord()
            currentStart = tokenStart
        } else if currentWord.isEmpty {
            currentStart = tokenStart
        }

        currentWord += tokenText
        currentEnd = max(currentEnd, tokenEnd)
    }
    flushWord()

    if words.count == fallbackWords.count {
        return zip(words, fallbackWords).map { word, fallbackWord in
            ParakeetWordTiming(
                word: fallbackWord,
                startTime: word.startTime,
                endTime: word.endTime
            )
        }
    }

    return words
}

private func makeParakeetSegments(from tokens: [ParakeetTokenTiming], fallbackText: String) -> [TranscriptSegment] {
    let words = makeParakeetWordTimings(from: tokens, fallbackText: fallbackText)
    guard !words.isEmpty else {
        let text = normalizedParakeetTranscriptText(fallbackText)
        return text.isEmpty ? [] : [TranscriptSegment(start: 0, end: 0.2, text: text)]
    }

    var segments: [TranscriptSegment] = []
    var currentText = ""
    var currentStart = max(0, words[0].startTime)
    var currentEnd = max(currentStart + 0.05, words[0].endTime)
    var previousEnd = currentEnd
    let preferredLineLength = 86
    let maximumLineLength = 118

    func flush() {
        let text = normalizedParakeetTranscriptText(currentText)
        guard !text.isEmpty else {
            currentText = ""
            return
        }
        segments.append(
            TranscriptSegment(
                start: max(0, currentStart),
                end: max(currentStart + 0.05, currentEnd),
                text: text
            )
        )
        currentText = ""
    }

    for word in words {
        let wordStart = max(0, word.startTime)
        let wordEnd = max(wordStart + 0.05, word.endTime)
        let gap = wordStart - previousEnd
        let normalizedCurrent = normalizedParakeetTranscriptText(currentText)
        let currentDuration = max(0, currentEnd - currentStart)
        let shouldBreakForGap = !currentText.isEmpty && gap > 0.85 && currentDuration >= 1.5
        let shouldBreakForSentence = currentDuration >= 1.2
            && normalizedCurrent.count >= 42
            && parakeetTextHasSegmentBoundary(normalizedCurrent)
        let shouldBreakForClause = normalizedCurrent.count >= preferredLineLength
            && parakeetTextHasClauseBoundary(normalizedCurrent)
        let shouldBreakForLength = normalizedCurrent.count >= maximumLineLength || currentDuration >= 10.0

        if shouldBreakForGap || shouldBreakForSentence || shouldBreakForClause || shouldBreakForLength {
            flush()
            currentStart = wordStart
            currentEnd = wordEnd
        }

        if currentText.isEmpty {
            currentText = word.word
        } else {
            currentText += " " + word.word
        }
        currentEnd = max(currentEnd, wordEnd)
        previousEnd = wordEnd
    }

    flush()
    guard segments.count > 1 else { return segments }

    var adjustedSegments: [TranscriptSegment] = []
    adjustedSegments.reserveCapacity(segments.count)
    for index in segments.indices {
        let segment = segments[index]
        let adjustedEnd: Double
        if index < segments.index(before: segments.endIndex) {
            let nextStart = segments[segments.index(after: index)].start
            adjustedEnd = max(segment.end, nextStart)
        } else {
            adjustedEnd = segment.end
        }
        adjustedSegments.append(
            TranscriptSegment(
                id: segment.id,
                start: segment.start,
                end: max(segment.start + 0.05, adjustedEnd),
                text: segment.text
            )
        )
    }
    return adjustedSegments
}

private func parseParakeetTranscriptionSegments(_ jsonData: Data) -> [TranscriptSegment] {
    guard let output = try? JSONDecoder().decode(ParakeetTranscriptionOutput.self, from: jsonData) else {
        return []
    }
    return makeParakeetSegments(from: output.tokenTimings, fallbackText: output.text)
}

public func transcribeAudioWithParakeet(
    file: URL,
    shouldCancel: @escaping @Sendable () -> Bool = { false },
    progressHandler: @escaping @Sendable (Double) -> Void = { _ in },
    progressPhaseHandler: @escaping @Sendable (String) -> Void = { _ in },
    onConsoleOutput: @escaping @Sendable (String, String) -> Void = { _, _ in },
    onTranscriptSegment: @escaping @Sendable (TranscriptSegment) -> Void = { _ in }
) -> Result<[TranscriptSegment], DetectionError> {
    if shouldCancel() {
        return .failure(.cancelled)
    }

    guard let ffmpegURL = findSystemFFmpegExecutable() else {
        return .failure(.failed("No ffmpeg executable found for Parakeet transcription."))
    }
    guard let parakeetURL = findParakeetTranscriberExecutable() else {
        return .failure(.failed("Bundled Parakeet transcriber not found (Contents/Resources/parakeet-transcriber)."))
    }
    guard let modelURL = findParakeetModelDirectory() else {
        return .failure(.failed("Bundled Parakeet model not found (Contents/Resources/parakeet-tdt-0.6b-v2)."))
    }

    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("bvt-parakeet-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    } catch {
        return .failure(.failed("Failed to create temp directory: \(error.localizedDescription)"))
    }
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let wavURL = tempRoot.appendingPathComponent("audio.wav")
    let outputJSON = tempRoot.appendingPathComponent("transcript.json")

    progressPhaseHandler("Extracting audio")
    let ffmpegResult = runSynchronousProcess(
        executableURL: ffmpegURL,
        arguments: [
            "-y",
            "-hide_banner",
            "-loglevel", "error",
            "-i", file.path,
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-f", "wav",
            wavURL.path
        ],
        shouldCancel: shouldCancel,
        source: "ffmpeg",
        onOutputLine: onConsoleOutput
    )
    switch ffmpegResult {
    case .failure(let error):
        return .failure(error)
    case .success:
        progressHandler(0.08)
    }

    let parakeetOutputHandler: @Sendable (String, String) -> Void = { line, source in
        onConsoleOutput(line, source)
        guard source == "parakeet",
              let helperProgress = parseParakeetProgressLine(line) else {
            return
        }
        if let phase = helperProgress.phase {
            progressPhaseHandler(phase)
        }
        progressHandler(0.08 + (helperProgress.progress * 0.90))
    }

    let parakeetResult = runSynchronousProcess(
        executableURL: parakeetURL,
        arguments: [
            wavURL.path,
            "--model-version", "v2",
            "--model-dir", modelURL.path,
            "--output-json", outputJSON.path
        ],
        shouldCancel: shouldCancel,
        source: "parakeet",
        onOutputLine: parakeetOutputHandler
    )
    switch parakeetResult {
    case .failure(let error):
        return .failure(error)
    case .success:
        progressPhaseHandler("Finalizing transcript")
        progressHandler(0.98)
    }

    guard let jsonData = try? Data(contentsOf: outputJSON) else {
        return .failure(.failed("Parakeet did not produce transcript JSON output."))
    }

    let segments = parseParakeetTranscriptionSegments(jsonData)
    for segment in segments {
        onTranscriptSegment(segment)
    }
    progressHandler(1.0)
    return .success(segments)
}

func computeProfanityHits(
    in transcriptSegments: [TranscriptSegment],
    profanityWords: Set<String>
) -> [ProfanityHit] {
    var hits: [ProfanityHit] = []
    for segment in transcriptSegments {
        let tokens = segment.text.split(whereSeparator: { $0.isWhitespace }).map { normalizedToken(String($0)) }
        let matchedWords = tokens.filter { profanityWords.contains($0) }
        if matchedWords.isEmpty { continue }
        let duration = segment.duration
        for word in matchedWords {
            hits.append(ProfanityHit(start: segment.start, end: segment.end, duration: duration, word: word))
        }
    }
    hits.sort { lhs, rhs in
        if abs(lhs.start - rhs.start) > 0.0001 { return lhs.start < rhs.start }
        return lhs.word < rhs.word
    }
    return hits
}

public func transcribeAudioWithWhisper(
    file: URL,
    shouldCancel: @escaping @Sendable () -> Bool = { false },
    progressHandler: @escaping @Sendable (Double) -> Void = { _ in },
    onConsoleOutput: @escaping @Sendable (String, String) -> Void = { _, _ in },
    onTranscriptSegment: @escaping @Sendable (TranscriptSegment) -> Void = { _ in }
) -> Result<[TranscriptSegment], DetectionError> {
    if shouldCancel() {
        return .failure(.cancelled)
    }

    guard let ffmpegURL = findSystemFFmpegExecutable() else {
        return .failure(.failed("No ffmpeg executable found for Whisper transcription."))
    }
    guard let whisperURL = findWhisperExecutable() else {
        return .failure(.failed("Bundled whisper-cli not found (Contents/Resources/whisper-cli)."))
    }
    guard let modelURL = findWhisperModel() else {
        return .failure(.failed("Bundled Whisper model not found (Contents/Resources/profanity-model.bin)."))
    }

    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("bvt-whisper-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    } catch {
        return .failure(.failed("Failed to create temp directory: \(error.localizedDescription)"))
    }
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let wavURL = tempRoot.appendingPathComponent("audio.wav")
    let outputPrefix = tempRoot.appendingPathComponent("transcript")
    let outputJSON = tempRoot.appendingPathComponent("transcript.json")

    let ffmpegResult = runSynchronousProcess(
        executableURL: ffmpegURL,
        arguments: [
            "-y",
            "-hide_banner",
            "-loglevel", "error",
            "-i", file.path,
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-f", "wav",
            wavURL.path
        ],
        shouldCancel: shouldCancel,
        source: "ffmpeg",
        onOutputLine: onConsoleOutput
    )
    switch ffmpegResult {
    case .failure(let error):
        return .failure(error)
    case .success:
        break
    }

    let whisperOutputHandler: @Sendable (String, String) -> Void = { line, source in
        onConsoleOutput(line, source)
        guard source == "whisper",
              let segment = parseStreamingTranscriptSegment(from: line) else {
            return
        }
        onTranscriptSegment(segment)
    }

    let whisperSegmentationArguments = [
        "-ml", "80",
        "-sow"
    ]

    let whisperResult = runSynchronousProcessWithProgress(
        executableURL: whisperURL,
        arguments: [
            "-m", modelURL.path,
            "-f", wavURL.path,
            "-of", outputPrefix.path,
            "-oj",
            "-pp"
        ] + whisperSegmentationArguments,
        shouldCancel: shouldCancel,
        progressHandler: progressHandler,
        source: "whisper",
        onOutputLine: whisperOutputHandler
    )
    switch whisperResult {
    case .success:
        break
    case .failure(.cancelled):
        return .failure(.cancelled)
    case .failure(.failed(let reason)):
        let cpuRetry = runSynchronousProcessWithProgress(
            executableURL: whisperURL,
            arguments: [
                "-ng",
                "-nfa",
                "-m", modelURL.path,
                "-f", wavURL.path,
                "-of", outputPrefix.path,
                "-oj",
                "-pp"
            ] + whisperSegmentationArguments,
            shouldCancel: shouldCancel,
            progressHandler: progressHandler,
            source: "whisper",
            onOutputLine: whisperOutputHandler
        )

        switch cpuRetry {
        case .success:
            break
        case .failure(.cancelled):
            return .failure(.cancelled)
        case .failure(.failed(let retryReason)):
            return .failure(.failed("Whisper transcription failed: \(retryReason). Initial error: \(reason)."))
        }
    }

    guard let jsonData = try? Data(contentsOf: outputJSON) else {
        return .failure(.failed("Whisper did not produce transcript JSON output."))
    }

    return .success(parseTranscriptionSegments(jsonData))
}

func detectProfanityHits(
    file: URL,
    profanityWords: Set<String>,
    cachedTranscriptSegments: [TranscriptSegment]? = nil,
    shouldCancel: @escaping @Sendable () -> Bool = { false },
    progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
) -> Result<[ProfanityHit], DetectionError> {
    if let cachedTranscriptSegments {
        progressHandler(1.0)
        return .success(computeProfanityHits(in: cachedTranscriptSegments, profanityWords: profanityWords))
    }

    let transcriptResult = transcribeAudioWithParakeet(
        file: file,
        shouldCancel: shouldCancel,
        progressHandler: progressHandler
    )
    switch transcriptResult {
    case .failure(let error):
        return .failure(error)
    case .success(let transcriptSegments):
        return .success(computeProfanityHits(in: transcriptSegments, profanityWords: profanityWords))
    }
}
