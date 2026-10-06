import AVFoundation
import Combine
import Foundation

private final class LockedCadenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var firstUpdateTime: TimeInterval?
    private var lastUpdateTime: TimeInterval?

    func recordUpdate() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if firstUpdateTime == nil {
            firstUpdateTime = now
        }
        lastUpdateTime = now
        count += 1
        lock.unlock()
    }

    func updatesPerSecond() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard count > 1,
              let firstUpdateTime,
              let lastUpdateTime,
              lastUpdateTime > firstUpdateTime else {
            return 0
        }
        return Double(count - 1) / (lastUpdateTime - firstUpdateTime)
    }
}

@main
@MainActor
struct AudioMeterSmoke {
    static func main() async {
        guard CommandLine.arguments.count == 5 else {
            fail(
                "Usage: audio-meter-smoke /path/to/stereo-audio " +
                    "/path/to/calibration-audio /path/to/full-scale-audio /path/to/silence"
            )
        }

        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let calibrationURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let fullScaleURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let silenceURL = URL(fileURLWithPath: CommandLine.arguments[4])
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let meter = AudioMeterPresentation()
        let cadenceRecorder = LockedCadenceRecorder()
        let valuesObserver = meter.$values.dropFirst().sink { _ in
            cadenceRecorder.recordUpdate()
        }
        defer { valuesObserver.cancel() }

        // Metering reads the file independently, so muting this test player does
        // not suppress measurements or alter the playback pipeline.
        player.isMuted = true
        meter.prepare(fileURL: url, at: 0)
        for _ in 0..<200 where meter.values.maximumPeak == 0 && meter.attachmentError == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard item.audioMix == nil else {
            fail("Preparing the meter unexpectedly modified the player audio mix")
        }

        let timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600),
            queue: .main
        ) { time in
            MainActor.assumeIsolated {
                meter.updatePlaybackTime(CMTimeGetSeconds(time))
            }
        }
        defer { player.removeTimeObserver(timeObserver) }
        player.play()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        player.pause()

        let values = meter.values
        let updatesPerSecond = cadenceRecorder.updatesPerSecond()
        guard meter.attachmentError == nil else {
            fail("Audio meter data failed: \(meter.attachmentError ?? "unknown error")")
        }
        guard values.leftPeak > 0.01 else {
            fail("Left channel did not produce a measurable peak")
        }
        guard values.rightPeak > values.leftPeak * 1.5 else {
            fail("Stereo channels were not measured independently")
        }
        guard values.maximumPeak >= values.rightPeak else {
            fail("Maximum peak did not retain the highest channel value")
        }
        // Audio buffers arrive at roughly 43 Hz for this 44.1 kHz fixture. The
        // UI interpolates these source updates at the display refresh rate.
        guard updatesPerSecond >= 35 else {
            fail(String(format: "Meter presentation cadence was only %.1f fps", updatesPerSecond))
        }

        meter.analyzeLoudness(fileURL: url, startSeconds: 0, endSeconds: 2)
        for _ in 0..<200 where meter.isAnalyzingLoudness {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard let loudness = meter.loudnessResult,
              loudness.integratedLUFS.isFinite,
              loudness.loudnessRangeLU.isFinite else {
            fail("Loudness analysis failed: \(meter.loudnessError ?? "no result")")
        }

        await verifyCalibratedLevels(fileURL: calibrationURL)
        await verifyClipping(fileURL: fullScaleURL)
        await verifySilence(fileURL: silenceURL)

        // Alternate between distant windows while readers are active. Cancellation
        // must remain cooperative so AVAssetReader is never torn down concurrently
        // with copyNextSampleBuffer.
        meter.detach(resetReadings: true)
        meter.prepare(fileURL: url, at: 0)
        for index in 0..<60 {
            meter.updatePlaybackTime(index.isMultiple(of: 2) ? 35 : 0)
            try? await Task.sleep(nanoseconds: 500_000)
        }
        meter.updatePlaybackTime(35)
        for _ in 0..<200 where meter.values.maximumPeak == 0 && meter.attachmentError == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard meter.values.maximumPeak > 0, meter.attachmentError == nil else {
            fail("Audio meter could not load a distant playback window")
        }

        meter.detach(resetReadings: true)
        guard item.audioMix == nil else {
            fail("Detaching the meter unexpectedly modified the player audio mix")
        }
        guard meter.values == .zero else {
            fail("Detaching the meter did not clear its readings")
        }

        print(
            String(
                format: "Audio meter smoke test passed (L %.4f, R %.4f, %.1f LUFS, %.1f fps)",
                values.leftPeak,
                values.rightPeak,
                loudness.integratedLUFS,
                updatesPerSecond
            )
        )
    }

    private static func verifyCalibratedLevels(fileURL: URL) async {
        let meter = AudioMeterPresentation()
        meter.prepare(fileURL: fileURL, at: 0.5)
        for _ in 0..<200 where meter.values.maximumPeak == 0 && meter.attachmentError == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard meter.attachmentError == nil else {
            fail("Calibrated meter data failed: \(meter.attachmentError ?? "unknown error")")
        }

        // Advance through prerecorded frames in real time so the 400 ms RMS
        // presentation average reaches steady state.
        for frame in 0..<180 {
            meter.updatePlaybackTime(0.5 + (Double(frame) / 60.0))
            try? await Task.sleep(nanoseconds: 8_000_000)
        }

        assertDB(
            amplitude: meter.values.leftPeak,
            expected: -6.0206,
            tolerance: 0.25,
            label: "10 kHz left peak"
        )
        assertDB(
            amplitude: meter.values.rightPeak,
            expected: -12.0412,
            tolerance: 0.25,
            label: "right peak"
        )
        assertDB(
            amplitude: meter.values.leftShortTerm,
            expected: -9.0309,
            tolerance: 0.30,
            label: "10 kHz left RMS"
        )
        assertDB(
            amplitude: meter.values.rightShortTerm,
            expected: -15.0515,
            tolerance: 0.30,
            label: "right RMS"
        )
        meter.detach(resetReadings: true)
    }

    private static func verifyClipping(fileURL: URL) async {
        let meter = AudioMeterPresentation()
        meter.prepare(fileURL: fileURL, at: 0.25)
        for _ in 0..<200 where !meter.values.isClipping && meter.attachmentError == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard meter.attachmentError == nil, meter.values.isClipping else {
            fail("A full-scale PCM signal did not set the clipping indicator")
        }
        assertDB(
            amplitude: meter.values.maximumPeak,
            expected: 0,
            tolerance: 0.01,
            label: "full-scale maximum peak"
        )
        meter.detach(resetReadings: true)
    }

    private static func verifySilence(fileURL: URL) async {
        let meter = AudioMeterPresentation()
        meter.prepare(fileURL: fileURL, at: 0.25)
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard meter.attachmentError == nil, meter.values == .zero else {
            fail("Digital silence produced a nonzero meter reading")
        }
        meter.detach(resetReadings: true)
    }

    private static func assertDB(
        amplitude: Double,
        expected: Double,
        tolerance: Double,
        label: String
    ) {
        let measured = amplitudeToDecibels(amplitude, floor: -120)
        guard abs(measured - expected) <= tolerance else {
            fail(
                String(
                    format: "%@ measured %.3f dBFS; expected %.3f ± %.3f dB",
                    label,
                    measured,
                    expected,
                    tolerance
                )
            )
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("ERROR: \(message)\n").utf8))
        exit(1)
    }
}
