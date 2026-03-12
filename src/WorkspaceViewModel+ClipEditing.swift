import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

extension WorkspaceViewModel {
    func resetProfanityWordsToDefaults() {
        profanityWordsText = defaultProfanityWordsStorageString
    }

    func addProfanityWords(from raw: String) {
        let additions = profanityWordsFromString(raw)
        guard !additions.isEmpty else { return }
        let merged = selectedProfanityWords.union(additions)
        profanityWordsText = merged.sorted().joined(separator: ", ")
    }

    func removeProfanityWord(_ word: String) {
        let token = normalizedToken(word)
        guard !token.isEmpty else { return }
        var words = selectedProfanityWords
        words.remove(token)
        profanityWordsText = words.sorted().joined(separator: ", ")
    }

    func resetAdvancedClipFilenameTemplateToDefaults() {
        advancedClipFilenamePreset = .sourceClipInOut
    }

    private func applyClipRange(start: Double, end: Double) {
        let duration = sourceDurationSeconds
        clipStartSeconds = min(max(0, start), duration)
        clipEndSeconds = min(max(0, end), duration)
        if clipEndSeconds < clipStartSeconds {
            clipEndSeconds = clipStartSeconds
        }
        clipStartText = formatSeconds(clipStartSeconds)
        clipEndText = formatSeconds(clipEndSeconds)
    }

    func syncClipTextFields() {
        clipStartText = formatSeconds(clipStartSeconds)
        clipEndText = formatSeconds(clipEndSeconds)
    }

    private func setClipRangeWithUndo(
        start: Double,
        end: Double,
        undoManager: UndoManager?,
        actionName: String
    ) {
        let previousStart = clipStartSeconds
        let previousEnd = clipEndSeconds
        applyClipRange(start: start, end: end)
        let didChange = abs(previousStart - clipStartSeconds) > 0.0001 || abs(previousEnd - clipEndSeconds) > 0.0001
        guard didChange, let undoManager else { return }
        let undoStart = previousStart
        let undoEnd = previousEnd
        undoManager.registerUndo(withTarget: self) { target in
            target.setClipRangeWithUndo(
                start: undoStart,
                end: undoEnd,
                undoManager: undoManager,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
    }

    func resetClipRange(undoManager: UndoManager? = nil) {
        let duration = max(0, sourceInfo?.durationSeconds ?? analysis?.mediaDuration ?? 0)
        setClipRangeWithUndo(start: 0, end: duration, undoManager: undoManager, actionName: "Clear Clip In/Out")
    }

    func applySuggestedClipBitrateFromSource() {
        let step = 0.5
        let sliderMin = 0.5
        let sliderMax = 20.0

        let suggested: Double
        if let sourceVideoBps = sourceInfo?.videoBitrateBps, sourceVideoBps > 0 {
            let sourceMbps = sourceVideoBps / 1_000_000.0
            let nearestTick = (sourceMbps / step).rounded() * step
            suggested = nearestTick + step
        } else {
            suggested = 4.0
        }

        originalModeDefaultBitrateMbps = min(sliderMax, max(sliderMin, suggested))
        if clipCompatibleMaxResolution == .original {
            clipVideoBitrateMbps = originalModeDefaultBitrateMbps
        }
    }

    func applySuggestedCompatibleBitrateForResolution() {
        // Only auto-adjust when user selects a capped resolution.
        let suggested: Double
        switch clipCompatibleMaxResolution {
        case .original:
            suggested = originalModeDefaultBitrateMbps
        case .p1080:
            suggested = 8.0
        case .p720:
            suggested = 5.0
        case .p480:
            suggested = 2.5
        }

        clipVideoBitrateMbps = min(20.0, max(0.5, suggested))
    }

    func preferredAudioTrackIndex(for asset: AVAsset) -> Int? {
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return nil }

        // Prefer the highest-bitrate audio track; this is usually the primary program audio.
        var bestIndex = 0
        var bestScore = audioTracks[0].estimatedDataRate
        for (index, track) in audioTracks.enumerated() {
            let score = track.estimatedDataRate
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return bestIndex
    }

    func clampClipRange() {
        applyClipRange(start: clipStartSeconds, end: clipEndSeconds)
    }

    func commitClipStartText(undoManager: UndoManager? = nil) {
        guard let parsed = parseTimecode(clipStartText) else {
            clipStartText = formatSeconds(clipStartSeconds)
            return
        }
        setClipStart(parsed, undoManager: undoManager)
    }

    func commitClipEndText(undoManager: UndoManager? = nil) {
        guard let parsed = parseTimecode(clipEndText) else {
            clipEndText = formatSeconds(clipEndSeconds)
            return
        }
        setClipEnd(parsed, undoManager: undoManager)
    }

    func setClipStart(_ time: Double, undoManager: UndoManager? = nil) {
        setClipRangeWithUndo(
            start: time,
            end: clipEndSeconds,
            undoManager: undoManager,
            actionName: "Set Clip Start"
        )
    }

    func setClipEnd(_ time: Double, undoManager: UndoManager? = nil) {
        setClipRangeWithUndo(
            start: clipStartSeconds,
            end: time,
            undoManager: undoManager,
            actionName: "Set Clip End"
        )
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard let provider = accepted.first else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.setSource(url)
            }
        }
        return true
    }
}
