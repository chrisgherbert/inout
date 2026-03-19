import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct EmptyToolView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    final class Coordinator {
        var lastResolvedWindowID: ObjectIdentifier?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let windowID = ObjectIdentifier(window)
            if context.coordinator.lastResolvedWindowID == windowID {
                return
            }
            context.coordinator.lastResolvedWindowID = windowID
            onResolve(window)
        }
    }
}

struct ContentView: View {
    @StateObject private var model: WorkspaceViewModel
    @ObservedObject private var externalOpenBridge = ExternalFileOpenBridge.shared
    @AppStorage("onboarding.urlDownloadSetupCompleted") private var urlDownloadSetupCompleted = false
    @AppStorage("onboarding.urlDownloadSetupDismissed") private var urlDownloadSetupDismissed = false
    @State private var isDropTargeted = false
    @State private var appWindow: NSWindow?
    @State private var showJobsPopover = false
    @State private var lastQueuedCount = 0
    @State private var lastPendingQueuedCount = 0
    @State private var showURLDownloadSetupSheet = false

    @MainActor init() {
        if PlayheadBenchmarkConfig.shared.enabled {
            PlayheadDiagnostics.shared.writeProgress(stage: "content_view_init", scenario: nil)
        }
        _model = StateObject(wrappedValue: WorkspaceViewModel())
    }

    private func syncWindowMetadata() {
        guard let appWindow else { return }
        appWindow.titleVisibility = .visible
        appWindow.titlebarAppearsTransparent = false
        appWindow.title = model.sourceURL?.lastPathComponent ?? "In/Out"
        appWindow.subtitle = ""
        appWindow.representedURL = model.sourceURL
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompactLayout = proxy.size.height < 760
            let contentPadding = isCompactLayout ? 8.0 : 12.0

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: isCompactLayout ? 8 : 10) {
                    ToolContentView(model: model, isCompactLayout: isCompactLayout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.top, contentPadding)
                .padding(.horizontal, contentPadding)
                .padding(.bottom, contentPadding)

                StatusFooterStripView(
                    activity: model.activityPresentation,
                    queuedJobs: model.queuedJobs,
                    isAnalyzing: model.isAnalyzing,
                    isExporting: model.isExporting,
                    isActivityRunning: model.isActivityRunning,
                    outputURL: model.outputURL,
                    stopCurrentActivity: { model.stopCurrentActivity() },
                    revealOutput: { model.revealOutput() }
                )
                    .padding(.horizontal, 0)
                    .padding(.bottom, contentPadding / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
                model.handleDrop(providers: providers)
            }
            .onOpenURL { url in
                guard url.isFileURL else { return }
                model.setSource(url)
                NSApp.activate(ignoringOtherApps: true)
            }
            .onReceive(externalOpenBridge.$incomingURL) { url in
                guard let url else { return }

                let visibleDocumentWindows = NSApp.windows.filter { window in
                    window.isVisible && !window.isMiniaturized && window.canBecomeMain
                }
                let canReuseSingleEmptyWindow =
                    visibleDocumentWindows.count == 1 &&
                    model.sourceURL == nil

                guard appWindow?.isKeyWindow == true || canReuseSingleEmptyWindow else { return }
                model.setSource(url)
                NSApp.activate(ignoringOtherApps: true)
                externalOpenBridge.incomingURL = nil
            }
        }
        .preferredColorScheme(model.appearance.colorScheme)
        .frame(minWidth: 980, minHeight: 700)
        .background(
            WindowAccessor { window in
                appWindow = window
                syncWindowMetadata()
            }
        )
        .onChange(of: model.sourceURL?.path) { _ in
            syncWindowMetadata()
        }
        .onChange(of: model.queuedJobs.count) { newCount in
            let pendingQueuedCount = model.queuedJobs.filter { $0.status == .queued }.count
            if pendingQueuedCount > lastPendingQueuedCount && model.isActivityRunning {
                showJobsPopover = true
            }
            if newCount == 0 {
                showJobsPopover = false
            }
            lastQueuedCount = newCount
            lastPendingQueuedCount = pendingQueuedCount
        }
        .onAppear {
            if PlayheadBenchmarkConfig.shared.enabled {
                PlayheadDiagnostics.shared.writeProgress(stage: "content_view_appeared", scenario: nil)
            }
            lastQueuedCount = model.queuedJobs.count
            lastPendingQueuedCount = model.queuedJobs.filter { $0.status == .queued }.count
            updateURLDownloadOnboardingPresentation()
        }
        .onChange(of: model.urlDownloadSetupComplete) { isComplete in
            if isComplete {
                urlDownloadSetupCompleted = true
                showURLDownloadSetupSheet = false
            }
        }
        .onChange(of: model.sourceURL?.path) { _ in
            updateURLDownloadOnboardingPresentation()
        }
        .sheet(isPresented: $showURLDownloadSetupSheet) {
            URLDownloadSetupSheet(
                model: model,
                onNotNow: {
                    urlDownloadSetupDismissed = true
                    showURLDownloadSetupSheet = false
                }
            )
            .preferredColorScheme(model.appearance.colorScheme)
        }
        .focusedSceneValue(\.workspaceModel, model)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showJobsPopover.toggle()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "list.bullet.rectangle.portrait")
                        if model.hasQueuedJobs {
                            Text("\(min(model.queuedJobs.count, 99))")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor, in: Capsule())
                                .foregroundStyle(.white)
                                .offset(x: 9, y: -8)
                        }
                    }
                }
                .help("Jobs")
                .popover(isPresented: $showJobsPopover, arrowEdge: .top) {
                    JobsPopoverView(model: model)
                }
            }
        }
    }

    private func updateURLDownloadOnboardingPresentation() {
        if PlayheadBenchmarkConfig.shared.enabled {
            showURLDownloadSetupSheet = false
            return
        }

        if model.urlDownloadSetupComplete {
            urlDownloadSetupCompleted = true
            showURLDownloadSetupSheet = false
            return
        }

        let shouldShow =
            model.sourceURL == nil &&
            !urlDownloadSetupCompleted &&
            !urlDownloadSetupDismissed

        showURLDownloadSetupSheet = shouldShow
    }
}

private struct URLDownloadSetupSheet: View {
    @ObservedObject var model: WorkspaceViewModel
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Install Web Download Tools")
                        .font(.title2.weight(.semibold))
                    Text("To download videos from supported sites, In/Out needs to install helper tools the first time you use this feature.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Local media files will work without these tools.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Label("In/Out will manage these tools for you automatically.", systemImage: "gearshape.2.fill")
                    .foregroundStyle(.secondary)
                Label("You can manage this later in Settings.", systemImage: "wrench.and.screwdriver.fill")
                    .foregroundStyle(.secondary)
            }
            .font(.body)

            if model.isUpdatingDownloader || !model.downloaderActionStatusText.isEmpty || !model.downloaderLastErrorText.isEmpty {
                HStack(alignment: .center, spacing: 10) {
                    if model.isUpdatingDownloader {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: model.downloaderLastErrorText.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(model.downloaderLastErrorText.isEmpty ? Color.green : Color.orange)
                    }

                    Text(model.downloaderLastErrorText.isEmpty ? model.downloaderActionStatusText : model.downloaderLastErrorText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 10) {
                Button("Not Now") {
                    onNotNow()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(model.isUpdatingDownloader ? "Installing…" : "Install Web Download Tools") {
                    model.repairDownloaderSupport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isUpdatingDownloader)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
