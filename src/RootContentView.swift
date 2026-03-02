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

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            onResolve(window)
        }
    }
}

struct ContentView: View {
    @StateObject private var model: WorkspaceViewModel
    @ObservedObject private var externalOpenBridge = ExternalFileOpenBridge.shared
    @State private var isDropTargeted = false
    @State private var appWindow: NSWindow?
    @State private var showJobsPopover = false
    @State private var lastQueuedCount = 0
    @State private var lastPendingQueuedCount = 0

    @MainActor init() {
        _model = StateObject(wrappedValue: WorkspaceViewModel())
    }

    private func syncWindowMetadata() {
        guard let appWindow else { return }
        appWindow.titleVisibility = .visible
        appWindow.titlebarAppearsTransparent = false
        appWindow.title = model.sourceURL?.lastPathComponent ?? "In & Out"
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

                StatusFooterStripView(model: model)
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
        .frame(minWidth: 980, minHeight: 640)
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
            lastQueuedCount = model.queuedJobs.count
            lastPendingQueuedCount = model.queuedJobs.filter { $0.status == .queued }.count
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
}
