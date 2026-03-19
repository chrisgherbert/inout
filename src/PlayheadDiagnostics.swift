import AppKit
import Foundation

struct PlayheadBenchmarkConfig {
    static let shared = PlayheadBenchmarkConfig()

    let enabled: Bool
    let outputURL: URL?
    let progressURL: URL?
    let exitWhenDone: Bool
    let scenarios: [PlayheadBenchmarkScenario]

    private init() {
        let env = ProcessInfo.processInfo.environment
        enabled = env["INOUT_PLAYHEAD_BENCHMARK"] == "1"
        if let outputPath = env["INOUT_PLAYHEAD_BENCHMARK_OUTPUT"], !outputPath.isEmpty {
            outputURL = URL(fileURLWithPath: outputPath)
        } else {
            outputURL = nil
        }
        if let progressPath = env["INOUT_PLAYHEAD_BENCHMARK_PROGRESS_OUTPUT"], !progressPath.isEmpty {
            progressURL = URL(fileURLWithPath: progressPath)
        } else if let outputURL {
            progressURL = outputURL.deletingPathExtension().appendingPathExtension("progress.json")
        } else {
            progressURL = nil
        }
        exitWhenDone = env["INOUT_PLAYHEAD_BENCHMARK_EXIT"] != "0"
        if let rawScenarios = env["INOUT_PLAYHEAD_BENCHMARK_SCENARIOS"], !rawScenarios.isEmpty {
            let parsed = rawScenarios
                .split(separator: ",")
                .compactMap { PlayheadBenchmarkScenario(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            scenarios = parsed.isEmpty ? PlayheadBenchmarkScenario.defaultScenarios : parsed
        } else {
            scenarios = PlayheadBenchmarkScenario.defaultScenarios
        }
    }
}

enum PlayheadBenchmarkScenario: String, Codable, CaseIterable {
    case slowDrag = "slow_drag"
    case fastScrub = "fast_scrub"
    case backAndForth = "back_and_forth"
    case edgeAutoPan = "edge_auto_pan"

    static let defaultScenarios: [PlayheadBenchmarkScenario] = [.slowDrag, .fastScrub, .backAndForth, .edgeAutoPan]
}

struct PlayheadTimingSummary: Codable {
    let averageMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let maxMs: Double
}

struct PlayheadCounterSummary: Codable {
    let count: Int
    let perSecond: Double
}

struct PlayheadBenchmarkScenarioSummary: Codable {
    let name: String
    let durationMs: Double
    let inputEvents: PlayheadCounterSummary
    let visualUpdates: PlayheadCounterSummary
    let inputInterval: PlayheadTimingSummary?
    let visualInterval: PlayheadTimingSummary?
    let inputToVisualLatency: PlayheadTimingSummary?
    let mainThreadPulse: PlayheadTimingSummary?
    let mainThreadStallsOver25Ms: Int
    let layoutPasses: PlayheadCounterSummary
    let updateNSViewPasses: PlayheadCounterSummary
    let fullTimelineUpdates: PlayheadCounterSummary
    let decorationUpdates: PlayheadCounterSummary
    let markerLayoutUpdates: PlayheadCounterSummary
    let waveformImageRebuilds: PlayheadCounterSummary
    let miniMapBodyEvaluations: PlayheadCounterSummary
    let utilityRowBodyEvaluations: PlayheadCounterSummary
    let selectionPanelBodyEvaluations: PlayheadCounterSummary
    let updateNSViewDuration: PlayheadTimingSummary?
    let decorationDuration: PlayheadTimingSummary?
    let markerLayoutDuration: PlayheadTimingSummary?
    let waveformRebuildDuration: PlayheadTimingSummary?
    let modelWrites: [String: Int]
}

struct PlayheadBenchmarkSummary: Codable {
    let generatedAtISO8601: String
    let scenarios: [PlayheadBenchmarkScenarioSummary]
}

struct PlayheadBenchmarkProgress: Codable {
    let generatedAtISO8601: String
    let stage: String
    let scenario: String?
}

@MainActor
final class PlayheadDiagnostics {
    static let shared = PlayheadDiagnostics()

    private struct RunningScenario {
        let name: String
        let startTime: CFTimeInterval
        var endTime: CFTimeInterval?
        var inputIntervals: [Double] = []
        var visualIntervals: [Double] = []
        var inputToVisualLatencies: [Double] = []
        var mainThreadPulseIntervals: [Double] = []
        var updateNSViewDurations: [Double] = []
        var decorationDurations: [Double] = []
        var markerLayoutDurations: [Double] = []
        var waveformRebuildDurations: [Double] = []
        var lastInputTime: CFTimeInterval?
        var lastVisualTime: CFTimeInterval?
        var pendingInputTimes: [CFTimeInterval] = []
        var inputEvents = 0
        var visualUpdates = 0
        var mainThreadStallsOver25Ms = 0
        var layoutPasses = 0
        var updateNSViewPasses = 0
        var fullTimelineUpdates = 0
        var decorationUpdates = 0
        var markerLayoutUpdates = 0
        var waveformImageRebuilds = 0
        var miniMapBodyEvaluations = 0
        var utilityRowBodyEvaluations = 0
        var selectionPanelBodyEvaluations = 0
        var modelWrites: [String: Int] = [:]
    }

    private let config = PlayheadBenchmarkConfig.shared
    private var currentScenario: RunningScenario?
    private var completedScenarios: [PlayheadBenchmarkScenarioSummary] = []
    private var mainThreadPulseTimer: DispatchSourceTimer?
    private var lastMainThreadPulseTimestamp: CFTimeInterval?

    var isEnabled: Bool { config.enabled }
    var isScenarioActive: Bool { currentScenario != nil }

    private init() {}

    func beginScenario(_ scenario: PlayheadBenchmarkScenario) {
        guard isEnabled else { return }
        currentScenario = RunningScenario(name: scenario.rawValue, startTime: CACurrentMediaTime())
        startMainThreadPulseMonitor()
        writeProgress(stage: "scenario_running", scenario: scenario.rawValue)
    }

    func endScenario() {
        guard var scenario = currentScenario else { return }
        scenario.endTime = CACurrentMediaTime()
        currentScenario = nil
        stopMainThreadPulseMonitor()
        completedScenarios.append(makeSummary(for: scenario))
        writeProgress(stage: "scenario_finished", scenario: scenario.name)
    }

    func writeSummaryIfConfigured() {
        guard isEnabled, let outputURL = config.outputURL else { return }
        let summary = PlayheadBenchmarkSummary(
            generatedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            scenarios: completedScenarios
        )
        do {
            let data = try JSONEncoder.pretty.encode(summary)
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: outputURL, options: .atomic)
        } catch {
            fputs("Failed to write playhead benchmark summary: \(error)\n", stderr)
        }
    }

    func finishBenchmarkAndMaybeExit() {
        guard isEnabled else { return }
        writeSummaryIfConfigured()
        writeProgress(stage: "completed", scenario: nil)
        if config.exitWhenDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }

    func noteScrubInput(source: String, seconds: Double) {
        guard var scenario = currentScenario else { return }
        let now = CACurrentMediaTime()
        if let last = scenario.lastInputTime {
            scenario.inputIntervals.append(now - last)
        }
        scenario.lastInputTime = now
        scenario.pendingInputTimes.append(now)
        scenario.inputEvents += 1
        currentScenario = scenario
        _ = source
        _ = seconds
    }

    func noteVisualPlayheadUpdate(source: String, seconds: Double) {
        guard var scenario = currentScenario else { return }
        let now = CACurrentMediaTime()
        if let last = scenario.lastVisualTime {
            scenario.visualIntervals.append(now - last)
        }
        scenario.lastVisualTime = now
        if !scenario.pendingInputTimes.isEmpty {
            let inputTime = scenario.pendingInputTimes.removeFirst()
            scenario.inputToVisualLatencies.append(now - inputTime)
        }
        scenario.visualUpdates += 1
        currentScenario = scenario
        _ = source
        _ = seconds
    }

    func noteLayoutPass(source: String) {
        guard var scenario = currentScenario else { return }
        scenario.layoutPasses += 1
        currentScenario = scenario
        _ = source
    }

    func noteUpdateNSView(duration: CFTimeInterval, didFullTimelineUpdate: Bool) {
        guard var scenario = currentScenario else { return }
        scenario.updateNSViewPasses += 1
        scenario.updateNSViewDurations.append(duration)
        if didFullTimelineUpdate {
            scenario.fullTimelineUpdates += 1
        }
        currentScenario = scenario
    }

    func noteDecorationUpdate(duration: CFTimeInterval) {
        guard var scenario = currentScenario else { return }
        scenario.decorationUpdates += 1
        scenario.decorationDurations.append(duration)
        currentScenario = scenario
    }

    func noteMarkerLayout(duration: CFTimeInterval) {
        guard var scenario = currentScenario else { return }
        scenario.markerLayoutUpdates += 1
        scenario.markerLayoutDurations.append(duration)
        currentScenario = scenario
    }

    func noteWaveformImageRebuild(duration: CFTimeInterval) {
        guard var scenario = currentScenario else { return }
        scenario.waveformImageRebuilds += 1
        scenario.waveformRebuildDurations.append(duration)
        currentScenario = scenario
    }

    func noteModelWrite(_ kind: String) {
        guard var scenario = currentScenario else { return }
        scenario.modelWrites[kind, default: 0] += 1
        currentScenario = scenario
    }

    func noteMiniMapBodyEvaluation() {
        guard var scenario = currentScenario else { return }
        scenario.miniMapBodyEvaluations += 1
        currentScenario = scenario
    }

    func noteUtilityRowBodyEvaluation() {
        guard var scenario = currentScenario else { return }
        scenario.utilityRowBodyEvaluations += 1
        currentScenario = scenario
    }

    func noteSelectionPanelBodyEvaluation() {
        guard var scenario = currentScenario else { return }
        scenario.selectionPanelBodyEvaluations += 1
        currentScenario = scenario
    }

    func writeProgress(stage: String, scenario: String?) {
        guard isEnabled, let progressURL = config.progressURL else { return }
        let progress = PlayheadBenchmarkProgress(
            generatedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            stage: stage,
            scenario: scenario
        )
        do {
            let data = try JSONEncoder.pretty.encode(progress)
            try FileManager.default.createDirectory(at: progressURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: progressURL, options: .atomic)
        } catch {
            fputs("Failed to write playhead benchmark progress: \(error)\n", stderr)
        }
    }

    private func startMainThreadPulseMonitor() {
        guard mainThreadPulseTimer == nil else { return }
        lastMainThreadPulseTimestamp = nil
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.handleMainThreadPulse()
        }
        mainThreadPulseTimer = timer
        timer.resume()
    }

    private func stopMainThreadPulseMonitor() {
        mainThreadPulseTimer?.cancel()
        mainThreadPulseTimer = nil
        lastMainThreadPulseTimestamp = nil
    }

    private func handleMainThreadPulse() {
        guard var scenario = currentScenario else { return }
        let now = CACurrentMediaTime()
        if let last = lastMainThreadPulseTimestamp {
            let delta = now - last
            scenario.mainThreadPulseIntervals.append(delta)
            if delta > 0.025 {
                scenario.mainThreadStallsOver25Ms += 1
            }
            currentScenario = scenario
        }
        lastMainThreadPulseTimestamp = now
    }

    private func makeSummary(for scenario: RunningScenario) -> PlayheadBenchmarkScenarioSummary {
        let endTime = scenario.endTime ?? CACurrentMediaTime()
        let duration = max(0.0001, endTime - scenario.startTime)
        return PlayheadBenchmarkScenarioSummary(
            name: scenario.name,
            durationMs: duration * 1000.0,
            inputEvents: counterSummary(count: scenario.inputEvents, duration: duration),
            visualUpdates: counterSummary(count: scenario.visualUpdates, duration: duration),
            inputInterval: timingSummary(scenario.inputIntervals),
            visualInterval: timingSummary(scenario.visualIntervals),
            inputToVisualLatency: timingSummary(scenario.inputToVisualLatencies),
            mainThreadPulse: timingSummary(scenario.mainThreadPulseIntervals),
            mainThreadStallsOver25Ms: scenario.mainThreadStallsOver25Ms,
            layoutPasses: counterSummary(count: scenario.layoutPasses, duration: duration),
            updateNSViewPasses: counterSummary(count: scenario.updateNSViewPasses, duration: duration),
            fullTimelineUpdates: counterSummary(count: scenario.fullTimelineUpdates, duration: duration),
            decorationUpdates: counterSummary(count: scenario.decorationUpdates, duration: duration),
            markerLayoutUpdates: counterSummary(count: scenario.markerLayoutUpdates, duration: duration),
            waveformImageRebuilds: counterSummary(count: scenario.waveformImageRebuilds, duration: duration),
            miniMapBodyEvaluations: counterSummary(count: scenario.miniMapBodyEvaluations, duration: duration),
            utilityRowBodyEvaluations: counterSummary(count: scenario.utilityRowBodyEvaluations, duration: duration),
            selectionPanelBodyEvaluations: counterSummary(count: scenario.selectionPanelBodyEvaluations, duration: duration),
            updateNSViewDuration: timingSummary(scenario.updateNSViewDurations),
            decorationDuration: timingSummary(scenario.decorationDurations),
            markerLayoutDuration: timingSummary(scenario.markerLayoutDurations),
            waveformRebuildDuration: timingSummary(scenario.waveformRebuildDurations),
            modelWrites: scenario.modelWrites.sorted { $0.key < $1.key }.reduce(into: [:]) { $0[$1.key] = $1.value }
        )
    }

    private func counterSummary(count: Int, duration: CFTimeInterval) -> PlayheadCounterSummary {
        PlayheadCounterSummary(count: count, perSecond: duration > 0 ? Double(count) / duration : 0)
    }

    private func timingSummary(_ samples: [Double]) -> PlayheadTimingSummary? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return PlayheadTimingSummary(
            averageMs: (samples.reduce(0, +) / Double(samples.count)) * 1000.0,
            p50Ms: percentile(sorted, 0.50) * 1000.0,
            p95Ms: percentile(sorted, 0.95) * 1000.0,
            maxMs: (sorted.last ?? 0) * 1000.0
        )
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(max(0, fraction), 1)
        let position = Double(sorted.count - 1) * clamped
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] + ((sorted[upper] - sorted[lower]) * weight)
    }
}

@MainActor
final class PlayheadBenchmarkCoordinator {
    static let shared = PlayheadBenchmarkCoordinator()

    struct Driver {
        let isReady: () -> Bool
        let maxZoomIndex: () -> Int
        let setZoomIndex: (Int) -> Void
        let beginScrubAtRatio: (Double) -> Void
        let updateScrubToRatio: (Double) -> Void
        let endScrubAtRatio: (Double) -> Void
    }

    private let config = PlayheadBenchmarkConfig.shared
    private var driver: Driver?
    private var didStart = false

    private init() {}

    func register(driver: Driver) {
        guard config.enabled else { return }
        self.driver = driver
        PlayheadDiagnostics.shared.writeProgress(stage: "driver_registered", scenario: nil)
        guard !didStart else { return }
        didStart = true
        Task { @MainActor in
            await runBenchmarksWhenReady()
        }
    }

    private func runBenchmarksWhenReady() async {
        PlayheadDiagnostics.shared.writeProgress(stage: "waiting_for_ready", scenario: nil)
        let deadline = CACurrentMediaTime() + 30.0
        while CACurrentMediaTime() < deadline {
            if let driver, driver.isReady() {
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        guard let driver, driver.isReady() else {
            PlayheadDiagnostics.shared.writeProgress(stage: "ready_timeout", scenario: nil)
            PlayheadDiagnostics.shared.finishBenchmarkAndMaybeExit()
            return
        }

        PlayheadDiagnostics.shared.writeProgress(stage: "ready", scenario: nil)

        for scenario in config.scenarios {
            await runScenario(scenario, driver: driver)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        PlayheadDiagnostics.shared.finishBenchmarkAndMaybeExit()
    }

    private func runScenario(_ scenario: PlayheadBenchmarkScenario, driver: Driver) async {
        let maxZoomIndex = driver.maxZoomIndex()
        switch scenario {
        case .slowDrag:
            driver.setZoomIndex(min(maxZoomIndex, 6))
            try? await Task.sleep(nanoseconds: 150_000_000)
            PlayheadDiagnostics.shared.beginScenario(scenario)
            await animateScrub(driver: driver, keyframes: [(0.12, 0.0), (0.88, 2.4)])
            PlayheadDiagnostics.shared.endScenario()
        case .fastScrub:
            driver.setZoomIndex(min(maxZoomIndex, 6))
            try? await Task.sleep(nanoseconds: 150_000_000)
            PlayheadDiagnostics.shared.beginScenario(scenario)
            await animateScrub(driver: driver, keyframes: [(0.10, 0.0), (0.90, 0.42)])
            PlayheadDiagnostics.shared.endScenario()
        case .backAndForth:
            driver.setZoomIndex(min(maxZoomIndex, 7))
            try? await Task.sleep(nanoseconds: 150_000_000)
            PlayheadDiagnostics.shared.beginScenario(scenario)
            await animateScrub(driver: driver, keyframes: [(0.20, 0.0), (0.82, 0.70), (0.34, 1.35), (0.78, 1.95), (0.28, 2.55)])
            PlayheadDiagnostics.shared.endScenario()
        case .edgeAutoPan:
            driver.setZoomIndex(min(maxZoomIndex, 10))
            try? await Task.sleep(nanoseconds: 150_000_000)
            PlayheadDiagnostics.shared.beginScenario(scenario)
            await animateScrub(driver: driver, keyframes: [(0.82, 0.0), (0.97, 0.25), (0.98, 1.35)])
            PlayheadDiagnostics.shared.endScenario()
        }
    }

    private func animateScrub(driver: Driver, keyframes: [(Double, Double)]) async {
        guard let first = keyframes.first else { return }
        driver.beginScrubAtRatio(first.0)
        var previous = first
        for next in keyframes.dropFirst() {
            let segmentDuration = max(0.0001, next.1 - previous.1)
            let steps = max(2, Int((segmentDuration * 60.0).rounded()))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let ratio = previous.0 + ((next.0 - previous.0) * t)
                driver.updateScrubToRatio(ratio)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            previous = next
        }
        driver.endScrubAtRatio(previous.0)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
