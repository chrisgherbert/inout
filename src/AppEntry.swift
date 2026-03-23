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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if PlayheadBenchmarkConfig.shared.enabled {
            PlayheadDiagnostics.shared.writeProgress(stage: "app_launched", scenario: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        guard !PlayheadBenchmarkConfig.shared.enabled else { return }
        Task { @MainActor in
            AppUpdateChecker.shared.performInitialCheckIfNeeded()
        }
    }
}

@main
struct CheckBlackFramesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workspaceModel) private var focusedModel
    @AppStorage("prefs.appearance") private var appearanceRawValue = AppAppearance.dark.rawValue

    private var appearanceColorScheme: ColorScheme? {
        AppAppearance(rawValue: appearanceRawValue)?.colorScheme ?? AppAppearance.dark.colorScheme
    }

    var body: some Scene {
        WindowGroup("In/Out", id: "main", for: UUID.self) { _ in
            ContentView()
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)

        Window("In/Out Help", id: "help") {
            HelpDocumentationView()
                .preferredColorScheme(appearanceColorScheme)
        }
        .defaultSize(width: 920, height: 700)
        .windowResizability(.contentSize)

        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    AppUpdateChecker.shared.checkForUpdates(userInitiated: true)
                }
            }

            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Set Clip Start at Playhead") {
                    NotificationCenter.default.post(name: .clipSetStartAtPlayhead, object: focusedModel)
                }
                .appKeyboardShortcut(AppShortcutCatalog.setClipStart)
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)

                Button("Set Clip End at Playhead") {
                    NotificationCenter.default.post(name: .clipSetEndAtPlayhead, object: focusedModel)
                }
                .appKeyboardShortcut(AppShortcutCatalog.setClipEnd)
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)

                Button("Clear Clip In/Out") {
                    NotificationCenter.default.post(name: .clipClearRange, object: focusedModel)
                }
                .appKeyboardShortcut(AppShortcutCatalog.clearClipRange)
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)

                Button {
                    NotificationCenter.default.post(name: .clipAddMarkerAtPlayhead, object: focusedModel)
                } label: {
                    Label("Add Marker at Playhead", systemImage: "mappin.and.ellipse")
                }
                .appKeyboardShortcut(AppShortcutCatalog.addMarker)
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)

                Button {
                    NotificationCenter.default.post(name: .clipJumpToStart, object: focusedModel)
                } label: {
                    Label("Previous Marker (or In/Out)", systemImage: "chevron.up.circle")
                }
                .appKeyboardShortcut(AppShortcutCatalog.previousMarker)
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)

                Button {
                    NotificationCenter.default.post(name: .clipJumpToEnd, object: focusedModel)
                } label: {
                    Label("Next Marker (or In/Out)", systemImage: "chevron.down.circle")
                }
                .appKeyboardShortcut(AppShortcutCatalog.nextMarker)
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
                .appKeyboardShortcut(AppShortcutCatalog.openMedia)

                Button {
                    focusedModel?.presentURLImportSheet()
                } label: {
                    Label("Download Media from URL…", systemImage: "link.badge.plus")
                }
                .appKeyboardShortcut(AppShortcutCatalog.downloadMediaFromURL)
                .disabled(!(focusedModel?.canRequestURLDownload ?? false))

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
                .appKeyboardShortcut(AppShortcutCatalog.exportAudio)
                .disabled(!(focusedModel?.canRequestAudioExport ?? false))

                Button {
                    focusedModel?.startClipExport()
                } label: {
                    Label("Export Clip…", systemImage: "film.stack")
                }
                .appKeyboardShortcut(AppShortcutCatalog.exportClip)
                .disabled(!(focusedModel?.canRequestClipExport ?? false))

                Button {
                    focusedModel?.startClipExport(skipSaveDialog: true)
                } label: {
                    Label("Quick Export Clip", systemImage: "film.stack.fill")
                }
                .appKeyboardShortcut(AppShortcutCatalog.quickExportClip)
                .disabled(!(focusedModel?.canRequestClipExport ?? false))

                Divider()

                Button {
                    NotificationCenter.default.post(name: .clipCaptureFrame, object: focusedModel)
                } label: {
                    Label("Capture Frame…", systemImage: "camera")
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil || focusedModel?.hasVideoTrack != true)
            }

            CommandMenu("Tool") {
                Button("Clip") { focusedModel?.selectedTool = .clip }
                    .appKeyboardShortcut(AppShortcutCatalog.switchToClip)
                .disabled(focusedModel == nil)
                Button("Analyze") { focusedModel?.selectedTool = .analyze }
                    .appKeyboardShortcut(AppShortcutCatalog.switchToAnalyze)
                .disabled(focusedModel == nil)
                Button("Convert") { focusedModel?.selectedTool = .convert }
                    .appKeyboardShortcut(AppShortcutCatalog.switchToConvert)
                .disabled(focusedModel == nil)
                Button("Inspect") { focusedModel?.selectedTool = .inspect }
                    .appKeyboardShortcut(AppShortcutCatalog.switchToInspect)
                .disabled(focusedModel == nil)
            }

            CommandMenu("Analyze") {
                Button {
                    focusedModel?.startAnalysis()
                } label: {
                    Label("Run Analysis", systemImage: "waveform.path.ecg")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!(focusedModel?.canRequestAnalyze ?? false))

                Button {
                    focusedModel?.stopCurrentActivity()
                } label: {
                    Label("Stop Analysis", systemImage: "stop.fill")
                }
                .appKeyboardShortcut(AppShortcutCatalog.stopCurrentTask)
                .disabled(!((focusedModel?.isAnalyzing ?? false) || (focusedModel?.isExporting ?? false)))
            }

            CommandMenu("View") {
                Button("Toggle Transcript") {
                    NotificationCenter.default.post(name: .clipToggleTranscriptSidebar, object: focusedModel)
                }
                .appKeyboardShortcut(AppShortcutCatalog.toggleTranscript)
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil || focusedModel?.hasAudioTrack != true)

                Divider()

                Button("Find in Transcript") {
                    NotificationCenter.default.post(name: .clipFocusTranscriptSearch, object: focusedModel)
                }
                .appKeyboardShortcut(AppShortcutCatalog.findInTranscript)
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil || focusedModel?.hasAudioTrack != true)

                Divider()

                Button("Zoom In Timeline") {
                    NotificationCenter.default.post(name: .clipTimelineZoomIn, object: focusedModel)
                }
                .appKeyboardShortcut(AppShortcutCatalog.commandZoomIn)
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)

                Button("Zoom Out Timeline") {
                    NotificationCenter.default.post(name: .clipTimelineZoomOut, object: focusedModel)
                }
                .appKeyboardShortcut(AppShortcutCatalog.commandZoomOut)
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)

                Button("Actual Timeline Size") {
                    NotificationCenter.default.post(name: .clipTimelineZoomReset, object: focusedModel)
                }
                .appKeyboardShortcut(AppShortcutCatalog.fitTimeline)
                .disabled(focusedModel?.selectedTool != .clip || focusedModel?.sourceURL == nil)
            }

            CommandGroup(replacing: .help) {
                Button("In/Out Help") {
                    openWindow(id: "help")
                }
                .appKeyboardShortcut(AppShortcutCatalog.openHelp)
            }
        }

        Settings {
            SettingsRootView()
        }
    }
}

private struct SettingsRootView: View {
    @StateObject private var model = WorkspaceViewModel()

    var body: some View {
        PreferencesView(model: model)
    }
}
