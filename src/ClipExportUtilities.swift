import AppKit
import Foundation
import InOutCore
import UniformTypeIdentifiers

struct ClipExportNamingInput {
    let sourceName: String
    let clipEncodingMode: ClipEncodingMode
    let selectedClipFormat: ClipFormat
    let clipAudioOnlyFormat: ClipAudioOnlyFormat
    let clipAdvancedVideoCodec: AdvancedVideoCodec
    let clipCompatibleMaxResolution: CompatibleMaxResolution
    let sourceResolution: String?
    let clipStartSeconds: Double
    let clipEndSeconds: Double
    let advancedFilenameTemplate: String
}

enum ClipExportUtilities {
    static func defaultClipExportFileName(_ input: ClipExportNamingInput) -> String {
        let outputExtension = input.clipEncodingMode == .audioOnly
            ? input.clipAudioOnlyFormat.fileExtension
            : input.selectedClipFormat.fileExtension

        let defaultBaseName: String
        if input.clipEncodingMode == .compressed {
            let codecToken = input.selectedClipFormat == .webm ? "vp9" : (input.clipAdvancedVideoCodec == .hevc ? "hevc" : "h264")
            let resolutionToken: String
            if input.clipCompatibleMaxResolution == .original {
                resolutionToken = input.sourceResolution ?? "original"
            } else {
                resolutionToken = input.clipCompatibleMaxResolution.rawValue
            }
            defaultBaseName = advancedClipFilenameBase(
                sourceName: input.sourceName,
                startSeconds: input.clipStartSeconds,
                endSeconds: input.clipEndSeconds,
                codec: codecToken,
                resolution: resolutionToken,
                advancedFilenameTemplate: input.advancedFilenameTemplate
            )
        } else {
            defaultBaseName = input.sourceName +
                "_clip_" + formatSeconds(input.clipStartSeconds).replacingOccurrences(of: ":", with: "-") +
                "_to_" + formatSeconds(input.clipEndSeconds).replacingOccurrences(of: ":", with: "-")
        }

        return URL(fileURLWithPath: defaultBaseName).deletingPathExtension().lastPathComponent + "." + outputExtension
    }

    static func promptClipExportDestination(
        defaultName: String,
        contentType: UTType
    ) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.title = "Export Clip"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func defaultAudioExportFileName(sourceURL: URL, selectedAudioFormat: AudioFormat) -> String {
        if selectedAudioFormat == .mp3 {
            return sourceURL.deletingPathExtension().lastPathComponent + ".mp3"
        }
        return sourceURL.deletingPathExtension().lastPathComponent + ".m4a"
    }

    static func promptAudioExportDestination(sourceURL: URL, selectedAudioFormat: AudioFormat) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultAudioExportFileName(sourceURL: sourceURL, selectedAudioFormat: selectedAudioFormat)
        panel.allowedContentTypes = selectedAudioFormat == .mp3 ? [.mp3] : [.mpeg4Audio]
        panel.canCreateDirectories = true
        panel.title = "Export Audio"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func advancedClipFilenameBase(
        sourceName: String,
        startSeconds: Double,
        endSeconds: Double,
        codec: String,
        resolution: String,
        advancedFilenameTemplate: String
    ) -> String {
        renderedAdvancedClipFilenameBase(
            sourceName: sourceName,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            codec: codec,
            resolution: resolution,
            advancedFilenameTemplate: advancedFilenameTemplate
        )
    }

    private static func renderedAdvancedClipFilenameBase(
        sourceName: String,
        startSeconds: Double,
        endSeconds: Double,
        codec: String,
        resolution: String,
        advancedFilenameTemplate: String
    ) -> String {
        let tcStart = formatSeconds(startSeconds).replacingOccurrences(of: ":", with: "-")
        let tcEnd = formatSeconds(endSeconds).replacingOccurrences(of: ":", with: "-")
        let duration = String(format: "%.3f", max(0, endSeconds - startSeconds))

        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH-mm-ss"

        let replacements: [String: String] = [
            "{source_name}": sanitizeFilenameComponent(sourceName),
            "{in_tc}": sanitizeFilenameComponent(tcStart),
            "{out_tc}": sanitizeFilenameComponent(tcEnd),
            "{duration}": sanitizeFilenameComponent(duration),
            "{date}": dateFormatter.string(from: now),
            "{time}": timeFormatter.string(from: now),
            "{codec}": sanitizeFilenameComponent(codec.lowercased()),
            "{resolution}": sanitizeFilenameComponent(resolution.lowercased().replacingOccurrences(of: " ", with: ""))
        ]

        var rendered = advancedFilenameTemplate
        for (token, value) in replacements {
            rendered = rendered.replacingOccurrences(of: token, with: value)
        }
        rendered = sanitizeFilenameComponent(rendered)
        if rendered.isEmpty {
            rendered = "\(sanitizeFilenameComponent(sourceName))_clip_\(tcStart)_to_\(tcEnd)"
        }
        return rendered
    }
}
