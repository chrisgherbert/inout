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
    @FocusedValue(\.workspaceModel) private var focusedModel
    @StateObject private var settingsModel = WorkspaceViewModel()

    var body: some Scene {
        WindowGroup("Bulwark Video Tools", id: "main", for: UUID.self) { _ in
            ContentView()
        }
        .windowResizability(.contentMinSize)

        Window("Bulwark Video Tools Help", id: "help") {
            HelpDocumentationView()
                .preferredColorScheme(settingsModel.appearance.colorScheme)
        }
        .defaultSize(width: 760, height: 680)
        .windowResizability(.contentSize)

        .commands {
            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Set Clip Start at Playhead") {
                    NotificationCenter.default.post(name: .clipSetStartAtPlayhead, object: focusedModel)
                }
                .keyboardShortcut("i", modifiers: [])
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)

                Button("Set Clip End at Playhead") {
                    NotificationCenter.default.post(name: .clipSetEndAtPlayhead, object: focusedModel)
                }
                .keyboardShortcut("o", modifiers: [])
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)

                Button("Clear Clip In/Out") {
                    NotificationCenter.default.post(name: .clipClearRange, object: focusedModel)
                }
                .keyboardShortcut("x", modifiers: [])
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)

                Button {
                    NotificationCenter.default.post(name: .clipAddMarkerAtPlayhead, object: focusedModel)
                } label: {
                    Label("Add Marker at Playhead", systemImage: "mappin.and.ellipse")
                }
                .keyboardShortcut("m", modifiers: [])
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)

                Button {
                    NotificationCenter.default.post(name: .clipJumpToStart, object: focusedModel)
                } label: {
                    Label("Previous Marker (or In/Out)", systemImage: "chevron.up.circle")
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)

                Button {
                    NotificationCenter.default.post(name: .clipJumpToEnd, object: focusedModel)
                } label: {
                    Label("Next Marker (or In/Out)", systemImage: "chevron.down.circle")
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)
            }

            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    openWindow(value: UUID())
                }
                .keyboardShortcut("n", modifiers: [.command])

                Divider()

                Button {
                    focusedModel?.chooseSource()
                } label: {
                    Label("Choose Media…", systemImage: "video.badge.plus")
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button {
                    focusedModel?.clearSource()
                } label: {
                    Label("Close Media", systemImage: "xmark.circle")
                }
                .disabled(focusedModel?.sourceURL == nil || focusedModel?.isAnalyzing == true || focusedModel?.isExporting == true)
            }

            CommandGroup(after: .saveItem) {
                Divider()

                Button {
                    focusedModel?.startExport()
                } label: {
                    Label("Export Audio…", systemImage: "arrow.down.doc")
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!(focusedModel?.canExport ?? false))

                Button {
                    focusedModel?.startClipExport()
                } label: {
                    Label("Export Clip…", systemImage: "film.stack")
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(!(focusedModel?.canExportClip ?? false))

                Button {
                    focusedModel?.startClipExport(skipSaveDialog: true)
                } label: {
                    Label("Quick Export Clip", systemImage: "film.stack.fill")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!(focusedModel?.canExportClip ?? false))

                Divider()

                Button {
                    NotificationCenter.default.post(name: .clipCaptureFrame, object: focusedModel)
                } label: {
                    Label("Capture Frame…", systemImage: "camera")
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil || focusedModel?.hasVideoTrack != true || focusedModel?.isAnalyzing == true || focusedModel?.isExporting == true)
            }

            CommandMenu("Tool") {
                Button("Clip") { focusedModel?.selectedTool = .clip }
                    .keyboardShortcut("1", modifiers: [.command])
                .disabled(focusedModel == nil)
                Button("Analyze") { focusedModel?.selectedTool = .analyze }
                    .keyboardShortcut("2", modifiers: [.command])
                .disabled(focusedModel == nil)
                Button("Convert") { focusedModel?.selectedTool = .convert }
                    .keyboardShortcut("3", modifiers: [.command])
                .disabled(focusedModel == nil)
                Button("Inspect") { focusedModel?.selectedTool = .inspect }
                    .keyboardShortcut("4", modifiers: [.command])
                .disabled(focusedModel == nil)
            }

            CommandMenu("Analyze") {
                Button {
                    focusedModel?.startAnalysis()
                } label: {
                    Label("Run Analysis", systemImage: "waveform.path.ecg")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!(focusedModel?.canAnalyze ?? false))

                Button {
                    focusedModel?.stopCurrentActivity()
                } label: {
                    Label("Stop Analysis", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!((focusedModel?.isAnalyzing ?? false) || (focusedModel?.isExporting ?? false)))
            }

            CommandMenu("View") {
                Button("Zoom In Timeline") {
                    NotificationCenter.default.post(name: .clipTimelineZoomIn, object: focusedModel)
                }
                .keyboardShortcut("=", modifiers: [.command])
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)

                Button("Zoom Out Timeline") {
                    NotificationCenter.default.post(name: .clipTimelineZoomOut, object: focusedModel)
                }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)

                Button("Actual Timeline Size") {
                    NotificationCenter.default.post(name: .clipTimelineZoomReset, object: focusedModel)
                }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)
            }

            CommandGroup(replacing: .help) {
                Button("Bulwark Video Tools Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            }
        }

        Settings {
            PreferencesView(model: settingsModel)
        }
    }
}
