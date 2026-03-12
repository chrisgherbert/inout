import Foundation
import AppKit
import AVFoundation
import SwiftUI

extension WorkspaceViewModel {
    func chooseCustomFrameSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a default folder for captured frames"
        panel.title = "Default Frame Save Location"
        if panel.runModal() == .OK, let url = panel.url {
            customFrameSaveDirectoryPath = url.path
        }
    }

    func captureFrame(at seconds: Double) {
        guard let sourceURL, hasVideoTrack else { return }

        let duration = sourceDurationSeconds
        let safeInput = seconds.isFinite ? seconds : 0
        let maxTime = duration > 0 ? max(0, duration - (1.0 / 600.0)) : safeInput
        let clampedTime = max(0, min(safeInput, maxTime))
        let defaultName = sourceURL.deletingPathExtension().lastPathComponent +
            "_frame_" + formatSeconds(clampedTime).replacingOccurrences(of: ":", with: "-") + ".png"

        let destinationURL: URL
        switch frameSaveLocationMode {
        case .askEachTime:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = defaultName
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            panel.title = "Save Frame"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destinationURL = url
        case .sourceFolder:
            let folder = sourceURL.deletingLastPathComponent()
            destinationURL = MediaToolUtilities.uniqueURL(in: folder, preferredFileName: defaultName)
        case .customFolder:
            let configuredFolder = URL(fileURLWithPath: customFrameSaveDirectoryPath)
            let folder: URL
            if !customFrameSaveDirectoryPath.isEmpty,
               FileManager.default.fileExists(atPath: configuredFolder.path) {
                folder = configuredFolder
            } else {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                panel.prompt = "Choose"
                panel.message = "Choose a default folder for captured frames"
                panel.title = "Default Frame Save Location"
                guard panel.runModal() == .OK, let picked = panel.url else { return }
                customFrameSaveDirectoryPath = picked.path
                folder = picked
            }
            destinationURL = MediaToolUtilities.uniqueURL(in: folder, preferredFileName: defaultName)
        }

        do {
            let asset = AVURLAsset(url: sourceURL)
            let captureTime = CMTime(seconds: clampedTime, preferredTimescale: 600)
            let cgImage: CGImage

            do {
                let strictGenerator = AVAssetImageGenerator(asset: asset)
                strictGenerator.appliesPreferredTrackTransform = true
                strictGenerator.requestedTimeToleranceBefore = CMTime(seconds: 1.0 / 120.0, preferredTimescale: 600)
                strictGenerator.requestedTimeToleranceAfter = CMTime(seconds: 1.0 / 120.0, preferredTimescale: 600)
                cgImage = try strictGenerator.copyCGImage(at: captureTime, actualTime: nil)
            } catch {
                // Fallback for files/timestamps where strict frame matching fails.
                let fallbackGenerator = AVAssetImageGenerator(asset: asset)
                fallbackGenerator.appliesPreferredTrackTransform = true
                fallbackGenerator.requestedTimeToleranceBefore = .positiveInfinity
                fallbackGenerator.requestedTimeToleranceAfter = .positiveInfinity
                cgImage = try fallbackGenerator.copyCGImage(at: captureTime, actualTime: nil)
            }

            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                uiMessage = "Frame capture failed: Unable to encode PNG."
                lastActivityState = .failed
                return
            }

            try pngData.write(to: destinationURL, options: .atomic)
            outputURL = destinationURL
            captureFrameFlashToken &+= 1
            uiMessage = "Frame saved: \(destinationURL.lastPathComponent)"
            lastActivityState = .success
            playFrameCaptureSound()
        } catch {
            let nsError = error as NSError
            uiMessage = "Frame capture failed (\(nsError.domain) \(nsError.code)): \(nsError.localizedDescription)"
            lastActivityState = .failed
        }
    }

    private func restoreMarkersWithUndo(
        _ markers: [CaptureTimelineMarker],
        highlightedID: UUID?,
        undoManager: UndoManager?,
        actionName: String
    ) {
        let currentMarkers = captureTimelineMarkers
        let currentHighlightedID = highlightedCaptureTimelineMarkerID
        captureTimelineMarkers = markers
        highlightedCaptureTimelineMarkerID = highlightedID
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreMarkersWithUndo(
                currentMarkers,
                highlightedID: currentHighlightedID,
                undoManager: undoManager,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
    }

    func addTimelineMarker(at seconds: Double, undoManager: UndoManager? = nil) {
        let previousMarkers = captureTimelineMarkers
        let previousHighlighted = highlightedCaptureTimelineMarkerID
        addCaptureTimelineMarker(at: seconds)
        let didChange = previousMarkers != captureTimelineMarkers
        if didChange {
            uiMessage = "Marker added at \(formatSeconds(seconds))"
            if let undoManager {
                undoManager.registerUndo(withTarget: self) { target in
                    target.restoreMarkersWithUndo(
                        previousMarkers,
                        highlightedID: previousHighlighted,
                        undoManager: undoManager,
                        actionName: "Add Marker"
                    )
                }
                undoManager.setActionName("Add Marker")
            }
        }
    }

    func nearestTimelineMarker(to seconds: Double, tolerance: Double) -> CaptureTimelineMarker? {
        guard tolerance >= 0 else { return nil }
        var nearest: CaptureTimelineMarker?
        var nearestDistance = Double.greatestFiniteMagnitude
        for marker in captureTimelineMarkers {
            let distance = abs(marker.seconds - seconds)
            guard distance <= tolerance, distance < nearestDistance else { continue }
            nearest = marker
            nearestDistance = distance
        }
        return nearest
    }

    func selectTimelineMarkerIfAligned(near seconds: Double, tolerance: Double = 1.0 / 30.0) {
        let next = nearestTimelineMarker(to: seconds, tolerance: tolerance)?.id
        if highlightedCaptureTimelineMarkerID != next {
            highlightedCaptureTimelineMarkerID = next
        }
    }

    func removeHighlightedTimelineMarker(undoManager: UndoManager? = nil) -> Bool {
        let previousMarkers = captureTimelineMarkers
        let previousHighlighted = highlightedCaptureTimelineMarkerID
        guard let highlightedID = highlightedCaptureTimelineMarkerID,
              let index = captureTimelineMarkers.firstIndex(where: { $0.id == highlightedID }) else {
            return false
        }
        captureTimelineMarkers.remove(at: index)
        highlightedCaptureTimelineMarkerID = nil
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.restoreMarkersWithUndo(
                    previousMarkers,
                    highlightedID: previousHighlighted,
                    undoManager: undoManager,
                    actionName: "Delete Marker"
                )
            }
            undoManager.setActionName("Delete Marker")
        }
        return true
    }

    func highlightTimelineMarker(near seconds: Double, tolerance: Double = 1.0 / 120.0) {
        if let marker = captureTimelineMarkers.first(where: { abs($0.seconds - seconds) <= tolerance }) {
            highlightedCaptureTimelineMarkerID = marker.id
            highlightedClipBoundary = nil
            scheduleCaptureMarkerHighlightClear(markerID: marker.id)
        } else {
            highlightedCaptureTimelineMarkerID = nil
        }
    }

    func highlightBoundaryIfNeeded(
        near seconds: Double,
        clipStart: Double,
        clipEnd: Double,
        tolerance: Double = 1.0 / 120.0
    ) {
        if abs(seconds - clipStart) <= tolerance {
            highlightedCaptureTimelineMarkerID = nil
            highlightedClipBoundary = .start
            scheduleClipBoundaryHighlightClear(.start)
            return
        }

        if abs(seconds - clipEnd) <= tolerance {
            highlightedCaptureTimelineMarkerID = nil
            highlightedClipBoundary = .end
            scheduleClipBoundaryHighlightClear(.end)
            return
        }

        highlightedClipBoundary = nil
    }

    private func addCaptureTimelineMarker(at seconds: Double) {
        let clamped = max(0, min(seconds, max(sourceDurationSeconds, seconds)))

        if let existing = captureTimelineMarkers.first(where: { abs($0.seconds - clamped) < 0.001 }) {
            highlightedCaptureTimelineMarkerID = existing.id
            scheduleCaptureMarkerHighlightClear(markerID: existing.id)
            return
        }

        let marker = CaptureTimelineMarker(seconds: clamped)
        captureTimelineMarkers.append(marker)
        captureTimelineMarkers.sort { $0.seconds < $1.seconds }
        if captureTimelineMarkers.count > 300 {
            captureTimelineMarkers.removeFirst(captureTimelineMarkers.count - 300)
        }
        highlightedCaptureTimelineMarkerID = marker.id
        scheduleCaptureMarkerHighlightClear(markerID: marker.id)
    }

    private func scheduleCaptureMarkerHighlightClear(markerID: UUID) {
        captureMarkerHighlightClearTask?.cancel()
        captureMarkerHighlightClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard let self, self.highlightedCaptureTimelineMarkerID == markerID else { return }
            if let marker = self.captureTimelineMarkers.first(where: { $0.id == markerID }),
               abs(marker.seconds - self.clipPlayheadSeconds) <= (1.0 / 30.0) {
                // Keep marker selected while playhead remains on it.
                return
            }
            withAnimation(.easeOut(duration: 0.18)) {
                self.highlightedCaptureTimelineMarkerID = nil
            }
        }
    }

    private func scheduleClipBoundaryHighlightClear(_ boundary: ClipBoundaryHighlight) {
        clipBoundaryHighlightClearTask?.cancel()
        clipBoundaryHighlightClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard let self, self.highlightedClipBoundary == boundary else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                self.highlightedClipBoundary = nil
            }
        }
    }

    private func playFrameCaptureSound() {
        if let bundledURL = Bundle.main.url(forResource: "FrameShutter", withExtension: "aiff"),
           let bundledSound = NSSound(contentsOf: bundledURL, byReference: true) {
            bundledSound.play()
            return
        }

        let preferred: [NSSound.Name] = [
            NSSound.Name("Grab"),   // macOS screenshot/Grab-style shutter sound
            NSSound.Name("Glass"),  // fallback
            NSSound.Name("Funk")    // fallback
        ]
        for name in preferred {
            if let sound = NSSound(named: name) {
                sound.play()
                return
            }
        }
    }

    func playQuickExportSnipSound() {
        if let bundledURL = Bundle.main.url(forResource: "QuickExportSnip", withExtension: "aiff"),
           let bundledSound = NSSound(contentsOf: bundledURL, byReference: true) {
            bundledSound.play()
            return
        }

        let preferred: [NSSound.Name] = [
            NSSound.Name("Pop"),
            NSSound.Name("Tink"),
            NSSound.Name("Glass")
        ]
        for name in preferred {
            if let sound = NSSound(named: name) {
                sound.play()
                return
            }
        }
    }
}
