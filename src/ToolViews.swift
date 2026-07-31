import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct LazyToolTabContent<Content: View>: View {
    let isActive: Bool
    let content: () -> Content

    var body: some View {
        Group {
            if isActive {
                content()
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct SourceHeaderView: View {
    @ObservedObject var model: WorkspaceViewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private func fileIcon(for url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(model.sourcePresentation.sourceURL == nil ? "Choose Media" : "Change Media") {
                model.chooseSource()
            }

            Spacer()

            if let sourceURL = model.sourcePresentation.sourceURL {
                HStack(spacing: 6) {
                    Image(nsImage: fileIcon(for: sourceURL))
                        .interpolation(.high)
                    Text(sourceURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    adaptiveContainerFill(
                        material: .thinMaterial,
                        fallback: Color(nsColor: .controlBackgroundColor),
                        reduceTransparency: reduceTransparency
                    ),
                    in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.45)
                )
                .help(sourceURL.path)
                .onDrag {
                    NSItemProvider(contentsOf: sourceURL) ?? NSItemProvider()
                }
                .contextMenu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sourceURL.path, forType: .string)
                    }
                }
            }
        }
        .padding(12)
        .background(
            adaptiveContainerFill(
                material: .regularMaterial,
                fallback: Color(nsColor: .windowBackgroundColor),
                reduceTransparency: reduceTransparency
            ),
            in: RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
    }
}

struct ToolContentView: View {
    @ObservedObject var model: WorkspaceViewModel
    let isCompactLayout: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        TabView(selection: $model.selectedTool) {
            LazyToolTabContent(isActive: model.selectedTool == .clip) {
                Group {
                    if model.sourceURL != nil {
                        ScrollView {
                            ClipToolView(
                                model: model,
                                sourcePresentation: model.sourcePresentation,
                                clipTimelinePresentation: model.clipTimelinePresentation,
                                isCompactLayout: isCompactLayout
                            )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("clip-\(model.sourceSessionID.uuidString)")
                        }
                        .scrollIndicators(.automatic)
                    } else {
                        ScrollView {
                            ClipToolView(
                                model: model,
                                sourcePresentation: model.sourcePresentation,
                                clipTimelinePresentation: model.clipTimelinePresentation,
                                isCompactLayout: isCompactLayout
                            )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("clip-\(model.sourceSessionID.uuidString)")
                        }
                        .scrollIndicators(.automatic)
                    }
                }
            }
            .padding(10)
            .tabItem { Text(WorkspaceTool.clip.rawValue) }
            .tag(WorkspaceTool.clip)

            LazyToolTabContent(isActive: model.selectedTool == .analyze) {
                ScrollView {
                    AnalyzeToolView(model: model, isCompactLayout: isCompactLayout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("analyze-\(model.sourceSessionID.uuidString)")
                }
            }
            .padding(10)
            .scrollIndicators(.automatic)
            .tabItem { Text(WorkspaceTool.analyze.rawValue) }
            .tag(WorkspaceTool.analyze)

            LazyToolTabContent(isActive: model.selectedTool == .convert) {
                ScrollView {
                    ConvertToolView(model: model, isCompactLayout: isCompactLayout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("convert-\(model.sourceSessionID.uuidString)")
                }
            }
            .padding(10)
            .scrollIndicators(.automatic)
            .tabItem { Text(WorkspaceTool.convert.rawValue) }
            .tag(WorkspaceTool.convert)

            LazyToolTabContent(isActive: model.selectedTool == .inspect) {
                ScrollView {
                    InspectToolView(
                        activity: model.activityPresentation,
                        sourceURL: model.sourceURL,
                        analysis: model.analysis,
                        sourceInfo: model.sourceInfo,
                        transcriptSegments: model.transcriptSegments,
                        transcriptStatusText: model.transcriptStatusText,
                        canGenerateTranscript: model.canGenerateTranscript,
                        isGeneratingTranscript: model.isGeneratingTranscript,
                        whisperTranscriptionAvailable: model.whisperTranscriptionAvailable,
                        hasAudioTrack: model.hasAudioTrack,
                        transcriptExportFormat: model.transcriptExportFormat,
                        transcriptDisplayMode: model.transcriptDisplayMode,
                        generateTranscript: { model.generateTranscript() },
                        setTranscriptExportFormat: { format in model.transcriptExportFormat = format },
                        setTranscriptDisplayMode: { mode in model.transcriptDisplayMode = mode },
                        exportTranscript: { format in model.exportTranscriptFromInspect(format: format) },
                        toggleActivityConsole: { model.showActivityConsole.toggle() },
                        copyActivityConsole: { model.copyActivityConsole() },
                        clearActivityConsole: { model.clearActivityConsole() },
                        isCompactLayout: isCompactLayout
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("inspect-\(model.sourceSessionID.uuidString)")
                }
            }
            .padding(10)
            .scrollIndicators(.automatic)
            .tabItem { Text(WorkspaceTool.inspect.rawValue) }
            .tag(WorkspaceTool.inspect)
        }
        .background(
            adaptiveContainerFill(
                material: .regularMaterial,
                fallback: Color(nsColor: .windowBackgroundColor),
                reduceTransparency: reduceTransparency
            ),
            in: RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIRadius.medium, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
    }
}

struct AnalyzeToolView: View {
    @ObservedObject var model: WorkspaceViewModel
    let isCompactLayout: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var blackFrameToggleBinding: Binding<Bool> {
        Binding(
            get: { model.hasVideoTrack ? model.analyzeBlackFrames : false },
            set: { model.analyzeBlackFrames = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.sourceURL != nil {
                HStack(spacing: 8) {
                    Button {
                        model.startAnalysis()
                    } label: {
                        Label(model.isAnalyzing ? "Analyzing…" : "Run Analysis", systemImage: "waveform.path.ecg")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRequestAnalyze)

                    if model.isAnalyzing {
                        Button {
                            model.stopAnalysis()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Toggle("Detect black frames", isOn: blackFrameToggleBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.isAnalyzing || !model.hasVideoTrack)

                Toggle("Detect silent audio gaps (over \(model.silenceMinDurationLabel)s)", isOn: $model.analyzeAudioSilence)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.isAnalyzing || !model.hasAudioTrack)

                Toggle("Detect profanity (Whisper transcription)", isOn: $model.analyzeProfanity)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.isAnalyzing || !model.hasAudioTrack)

                if let analysis = model.analysis {
                    Text(analysis.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Group {
                    if let analysis = model.analysis {
                        DetailView(
                            file: analysis,
                            isCompactLayout: isCompactLayout,
                            model: model,
                            activity: model.activityPresentation
                        )
                    } else {
                        Text("Ready to analyze")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            } else {
                EmptyToolView(title: "Analyze", subtitle: "Choose media and run analysis.")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.sourceURL != nil)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.analysis?.summary ?? "")
    }
}

struct ConvertToolView: View {
    @ObservedObject var model: WorkspaceViewModel
    let isCompactLayout: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var exportMode: ClipEncodingMode

    init(model: WorkspaceViewModel, isCompactLayout: Bool) {
        self.model = model
        self.isCompactLayout = isCompactLayout
        _exportMode = State(initialValue: model.hasVideoTrack ? .compressed : .audioOnly)
    }

    private var estimatedOutputSizeBytes: Int64? {
        switch exportMode {
        case .compressed:
            return model.estimatedFullSourceAdvancedSizeBytes
        case .audioOnly:
            return model.estimatedFullSourceAudioOnlySizeBytes
        case .fast:
            return nil
        }
    }

    private func resolveAvailableExportMode() {
        if exportMode == .compressed, !model.hasVideoTrack, model.hasAudioTrack {
            exportMode = .audioOnly
        } else if exportMode == .audioOnly, !model.hasAudioTrack, model.hasVideoTrack {
            exportMode = .compressed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.sourceURL != nil {
                Group {
                    GroupBox("Export Media") {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 8) {
                                Picker("Export type", selection: $exportMode) {
                                    if model.hasVideoTrack {
                                        Text("Video").tag(ClipEncodingMode.compressed)
                                    }
                                    if model.hasAudioTrack {
                                        Text("Audio Only").tag(ClipEncodingMode.audioOnly)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .controlSize(.regular)
                                .frame(maxWidth: .infinity)

                                Text(
                                    exportMode == .compressed
                                        ? "Export the complete video using the same options as Advanced clip export."
                                        : "Export the complete audio track using the same options as Audio Only clip export."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                Divider()

                                if exportMode == .compressed {
                                    AdvancedVideoExportOptions(model: model, formats: ClipFormat.allCases)
                                } else {
                                    AudioOnlyExportOptions(model: model)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            Divider()

                            HStack {
                                if estimatedOutputSizeBytes != nil {
                                    HStack(spacing: 8) {
                                        Label("Estimated output size", systemImage: "ruler")
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.tertiary)
                                        EstimatedSizePill(
                                            bytes: estimatedOutputSizeBytes,
                                            warningThresholdGB: model.estimatedSizeWarningThresholdGB,
                                            dangerThresholdGB: model.estimatedSizeDangerThresholdGB
                                        )
                                    }
                                }
                                Spacer(minLength: 8)
                                Button {
                                    model.startFullSourceExport(mode: exportMode)
                                } label: {
                                    Label(
                                        model.isActivityRunning
                                            ? "Queue Export"
                                            : (exportMode == .compressed ? "Export Video" : "Export Audio"),
                                        systemImage: model.isActivityRunning ? "text.badge.plus" : "arrow.down.doc"
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.canRequestFullSourceExport(mode: exportMode))
                            }
                        }
                        .padding(10)
                        .background(
                            adaptiveContainerFill(
                                material: .thinMaterial,
                                fallback: Color(nsColor: .controlBackgroundColor),
                                reduceTransparency: reduceTransparency
                            ),
                            in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                                .stroke(Color.primary.opacity(0.045), lineWidth: 0.4)
                        )
                    }

                    if let source = model.sourceURL {
                        Text("Source: \(source.path)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            } else {
                EmptyToolView(title: "Convert", subtitle: "Choose source media to enable video or audio export.")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.sourceURL != nil)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.isExporting)
        .onAppear {
            resolveAvailableExportMode()
        }
        .onChange(of: model.hasVideoTrack) { _, _ in
            resolveAvailableExportMode()
        }
        .onChange(of: model.hasAudioTrack) { _, _ in
            resolveAvailableExportMode()
        }
    }
}
