import SwiftUI
import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private func firstExistingFileURL(from paths: [String]) -> URL? {
        for path in paths {
            guard !path.isEmpty else { continue }
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let url = firstExistingFileURL(from: filenames) {
            DispatchQueue.main.async {
                ExternalFileOpenBridge.shared.open(url)
            }
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard let url = firstExistingFileURL(from: [filename]) else { return false }
        DispatchQueue.main.async {
            ExternalFileOpenBridge.shared.open(url)
        }
        return true
    }
}

@main
struct CheckBlackFramesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = WorkspaceViewModel()

    var body: some Scene {
        Window("Bulwark Video Tools", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .windowResizability(.contentMinSize)

        Window("Bulwark Video Tools Help", id: "help") {
            HelpDocumentationView()
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .defaultSize(width: 760, height: 680)
        .windowResizability(.contentSize)

        .commands {
            CommandMenu("Clip") {
                Button("Set Clip Start at Playhead") {
                    NotificationCenter.default.post(name: .clipSetStartAtPlayhead, object: nil)
                }
                .keyboardShortcut("i", modifiers: [])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil)

                Button("Set Clip End at Playhead") {
                    NotificationCenter.default.post(name: .clipSetEndAtPlayhead, object: nil)
                }
                .keyboardShortcut("o", modifiers: [])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil)

                Button("Clear Clip In/Out") {
                    NotificationCenter.default.post(name: .clipClearRange, object: nil)
                }
                .keyboardShortcut("x", modifiers: [])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil)

                Button {
                    NotificationCenter.default.post(name: .clipAddMarkerAtPlayhead, object: nil)
                } label: {
                    Label("Add Marker at Playhead", systemImage: "mappin.and.ellipse")
                }
                .keyboardShortcut("m", modifiers: [])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil)

                Button {
                    NotificationCenter.default.post(name: .clipJumpToStart, object: nil)
                } label: {
                    Label("Previous Marker (or In/Out)", systemImage: "chevron.up.circle")
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil)

                Button {
                    NotificationCenter.default.post(name: .clipJumpToEnd, object: nil)
                } label: {
                    Label("Next Marker (or In/Out)", systemImage: "chevron.down.circle")
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil)
            }

            CommandGroup(replacing: .newItem) {
                Button {
                    model.chooseSource()
                } label: {
                    Label("Choose Media…", systemImage: "video.badge.plus")
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button {
                    model.clearSource()
                } label: {
                    Label("Close Media", systemImage: "xmark.circle")
                }
                .disabled(model.sourceURL == nil || model.isAnalyzing || model.isExporting)
            }

            CommandGroup(after: .saveItem) {
                Divider()

                Button {
                    model.startExport()
                } label: {
                    Label("Export Audio…", systemImage: "arrow.down.doc")
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!model.canExport)

                Button {
                    model.startClipExport()
                } label: {
                    Label("Export Clip…", systemImage: "film.stack")
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(!model.canExportClip)

                Button {
                    model.startClipExport(skipSaveDialog: true)
                } label: {
                    Label("Quick Export Clip", systemImage: "film.stack.fill")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.canExportClip)

                Divider()

                Button {
                    NotificationCenter.default.post(name: .clipCaptureFrame, object: nil)
                } label: {
                    Label("Capture Frame…", systemImage: "camera")
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil || !model.hasVideoTrack || model.isAnalyzing || model.isExporting)
            }

            CommandMenu("Tool") {
                Button("Clip") { model.selectedTool = .clip }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Analyze") { model.selectedTool = .analyze }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Convert") { model.selectedTool = .convert }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("Inspect") { model.selectedTool = .inspect }
                    .keyboardShortcut("4", modifiers: [.command])
            }

            CommandMenu("Analyze") {
                Button {
                    model.startAnalysis()
                } label: {
                    Label("Run Analysis", systemImage: "waveform.path.ecg")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!model.canAnalyze)

                Button {
                    model.stopCurrentActivity()
                } label: {
                    Label("Stop Analysis", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!model.isAnalyzing && !model.isExporting)
            }

            CommandMenu("View") {
                Button("Zoom In Timeline") {
                    NotificationCenter.default.post(name: .clipTimelineZoomIn, object: nil)
                }
                .keyboardShortcut("=", modifiers: [.command])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil)

                Button("Zoom Out Timeline") {
                    NotificationCenter.default.post(name: .clipTimelineZoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil)

                Button("Actual Timeline Size") {
                    NotificationCenter.default.post(name: .clipTimelineZoomReset, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(model.selectedTool != .clip || model.sourceURL == nil)
            }

            CommandGroup(replacing: .help) {
                Button("Bulwark Video Tools Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            }
        }

        Settings {
            PreferencesView(model: model)
        }
    }
}
