import SwiftUI
import AppKit
import AVFoundation

struct ClipOutputPanel: View {
    @ObservedObject var model: WorkspaceViewModel
    let reduceTransparency: Bool
    let isOptionKeyPressed: Bool
    let fastClipFormats: [ClipFormat]
    let advancedClipFormats: [ClipFormat]
    let onStartExport: (_ quickExport: Bool) -> Void
    let onEnqueueExport: (_ quickExport: Bool) -> Void
    @State private var uiClipEncodingMode: ClipEncodingMode

    init(
        model: WorkspaceViewModel,
        reduceTransparency: Bool,
        isOptionKeyPressed: Bool,
        fastClipFormats: [ClipFormat],
        advancedClipFormats: [ClipFormat],
        onStartExport: @escaping (_ quickExport: Bool) -> Void,
        onEnqueueExport: @escaping (_ quickExport: Bool) -> Void
    ) {
        self.model = model
        self.reduceTransparency = reduceTransparency
        self.isOptionKeyPressed = isOptionKeyPressed
        self.fastClipFormats = fastClipFormats
        self.advancedClipFormats = advancedClipFormats
        self.onStartExport = onStartExport
        self.onEnqueueExport = onEnqueueExport
        _uiClipEncodingMode = State(initialValue: model.clipEncodingMode)
    }

    private func syncModelEncodingModeIfNeeded() {
        if model.clipEncodingMode != uiClipEncodingMode {
            model.clipEncodingMode = uiClipEncodingMode
        }
    }

    private var exportButtonTitle: String {
        if model.isGeneratingTranscript {
            return "Generating Transcript…"
        }
        if model.isActivityRunning {
            return "Queue Clip"
        }
        return isOptionKeyPressed ? "Quick Export Clip" : "Export Clip"
    }

    private var exportButtonSymbolName: String {
        if model.isGeneratingTranscript {
            return "captions.bubble"
        }
        return model.isActivityRunning ? "text.badge.plus" : "film.stack"
    }

    private var exportButtonHelpText: String {
        if model.isGeneratingTranscript {
            return "Clip export is unavailable while a transcript is being generated."
        }
        return model.isActivityRunning
            ? "Queue this clip export in the current window."
            : "Export Clip. Option-click for Quick Export (no save dialog)."
    }

    var body: some View {
        GroupBox("Output") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $uiClipEncodingMode) {
                        if model.hasVideoTrack {
                            Text("Fast").tag(ClipEncodingMode.fast)
                            Text("Advanced").tag(ClipEncodingMode.compressed)
                        }
                        Text("Audio Only").tag(ClipEncodingMode.audioOnly)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)

                    Text(
                        uiClipEncodingMode == .fast
                        ? "Fast mode uses passthrough copy with minimal processing."
                        : uiClipEncodingMode == .compressed
                            ? "Advanced mode unlocks codec, container, resolution, and bitrate options."
                            : "Audio Only exports only audio from the selected clip range."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Divider()

                    Group {
                        if uiClipEncodingMode == .audioOnly {
                            VStack(alignment: .leading, spacing: 10) {
                                LabeledContent("Audio format") {
                                    Picker("Audio format", selection: $model.clipAudioOnlyFormat) {
                                        ForEach(ClipAudioOnlyFormat.allCases) { format in
                                            Text(format.rawValue).tag(format)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .frame(width: 148)
                                }

                                HStack {
                                    Text("Audio bitrate")
                                        .frame(width: 120, alignment: .leading)
                                    Slider(
                                        value: Binding(
                                            get: { Double(model.clipAudioBitrateKbps) },
                                            set: { model.clipAudioBitrateKbps = Int($0.rounded()) }
                                        ),
                                        in: 64...320,
                                        step: 32
                                    )
                                    .controlSize(.small)
                                    Text("\(model.clipAudioBitrateKbps) kbps")
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 90, alignment: .trailing)
                                }

                                HStack(spacing: 10) {
                                    Toggle(
                                        "Boost audio (+\(model.clipAdvancedBoostAmount.rawValue) dB, limit -0.1 dBFS)",
                                        isOn: $model.clipAudioOnlyBoostAudio
                                    )
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                    if model.clipAudioOnlyBoostAudio {
                                        Picker("Boost amount", selection: $model.clipAdvancedBoostAmount) {
                                            ForEach(AdvancedBoostAmount.allCases) { amount in
                                                Text(amount.label).tag(amount)
                                            }
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                        .controlSize(.mini)
                                        .frame(width: 88, alignment: .leading)
                                        .help("Input gain before limiter.")
                                    }

                                    Spacer(minLength: 0)
                                }

                                Toggle("Add audio fade in/out (0.33s at start/end)", isOn: $model.clipAudioOnlyAddFadeInOut)
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                            }
                        } else if uiClipEncodingMode == .fast {
                            LabeledContent("Format") {
                                Picker("Format", selection: $model.selectedClipFormat) {
                                    ForEach(fastClipFormats) { format in
                                        Text(format.rawValue).tag(format)
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 148)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                LabeledContent("Format") {
                                    Picker("Format", selection: $model.selectedClipFormat) {
                                        ForEach(advancedClipFormats) { format in
                                            Text(format.rawValue).tag(format)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .frame(width: 148)
                                }

                                if model.selectedClipFormat != .webm {
                                    LabeledContent("Video codec") {
                                        Picker("Video codec", selection: $model.clipAdvancedVideoCodec) {
                                            ForEach(AdvancedVideoCodec.allCases) { codec in
                                                Text(codec.rawValue).tag(codec)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .labelsHidden()
                                        .controlSize(.small)
                                        .frame(width: 148)
                                    }
                                } else {
                                    Text("Video codec: VP9 (WebM)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                LabeledContent("Speed") {
                                    Picker("Speed", selection: $model.clipCompatibleSpeedPreset) {
                                        ForEach(CompatibleSpeedPreset.allCases) { preset in
                                            Text(preset.rawValue).tag(preset)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .frame(width: 148)
                                }

                                LabeledContent("Max resolution") {
                                    Picker("Max resolution", selection: $model.clipCompatibleMaxResolution) {
                                        ForEach(CompatibleMaxResolution.allCases) { resolution in
                                            Text(resolution.rawValue).tag(resolution)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .frame(width: 148)
                                }

                                HStack {
                                    Text("Video bitrate")
                                        .frame(width: 120, alignment: .leading)
                                    Slider(value: $model.clipVideoBitrateMbps, in: 0.5...20, step: 0.5)
                                        .controlSize(.small)
                                    Text(String(format: "%.1f Mbps", model.clipVideoBitrateMbps))
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 90, alignment: .trailing)
                                }

                                HStack {
                                    Text("Audio bitrate")
                                        .frame(width: 120, alignment: .leading)
                                    Slider(
                                        value: Binding(
                                            get: { Double(model.clipAudioBitrateKbps) },
                                            set: { model.clipAudioBitrateKbps = Int($0.rounded()) }
                                        ),
                                        in: 64...320,
                                        step: 32
                                    )
                                    .controlSize(.small)
                                    Text("\(model.clipAudioBitrateKbps) kbps")
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 90, alignment: .trailing)
                                }

                                HStack(spacing: 10) {
                                    Toggle(
                                        "Boost audio (+\(model.clipAdvancedBoostAmount.rawValue) dB, limit -0.1 dBFS)",
                                        isOn: $model.clipAdvancedBoostAudio
                                    )
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                    if model.clipAdvancedBoostAudio {
                                        Picker("Boost amount", selection: $model.clipAdvancedBoostAmount) {
                                            ForEach(AdvancedBoostAmount.allCases) { amount in
                                                Text(amount.label).tag(amount)
                                            }
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                        .controlSize(.mini)
                                        .frame(width: 88, alignment: .leading)
                                        .help("Input gain before limiter.")
                                    }

                                    Spacer(minLength: 0)
                                }

                                Toggle("Add audio fade in/out (0.33s at start/end)", isOn: $model.clipAdvancedAddFadeInOut)
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                HStack(spacing: 10) {
                                    Toggle("Auto-generate and burn captions (Whisper)", isOn: $model.clipAdvancedBurnInCaptions)
                                        .toggleStyle(.switch)
                                        .controlSize(.mini)
                                        .disabled(!model.whisperTranscriptionAvailable)

                                    if model.clipAdvancedBurnInCaptions {
                                        Picker("Caption style", selection: $model.clipAdvancedCaptionStyle) {
                                            ForEach(BurnInCaptionStyle.allCases) { style in
                                                Text(style.rawValue).tag(style)
                                            }
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                        .controlSize(.mini)
                                        .frame(width: 168, alignment: .leading)
                                        .disabled(!model.whisperTranscriptionAvailable)
                                        .help("Caption style for this export.")
                                    }

                                    Spacer(minLength: 0)
                                }

                                if !model.whisperTranscriptionAvailable {
                                    Text("Whisper binary/model not available in app bundle.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption)
                .foregroundStyle(.secondary)
                .tint(.secondary)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: UIRadius.small, style: .continuous)
                        .stroke(Color.primary.opacity(0.05), lineWidth: 0.45)
                )

                Divider()

                HStack {
                    if uiClipEncodingMode == .audioOnly, model.clipAudioOnlyFormat != .wav {
                        HStack(spacing: 8) {
                            Label("Estimated output size", systemImage: "ruler")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.tertiary)
                            EstimatedSizePill(
                                bytes: model.estimatedClipAudioOnlySizeBytes,
                                warningThresholdGB: model.estimatedSizeWarningThresholdGB,
                                dangerThresholdGB: model.estimatedSizeDangerThresholdGB
                            )
                        }
                    } else if uiClipEncodingMode == .compressed {
                        HStack(spacing: 8) {
                            Label("Estimated output size", systemImage: "ruler")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.tertiary)
                            EstimatedSizePill(
                                bytes: model.estimatedClipAdvancedSizeBytes,
                                warningThresholdGB: model.estimatedSizeWarningThresholdGB,
                                dangerThresholdGB: model.estimatedSizeDangerThresholdGB
                            )
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        let quickExport = NSEvent.modifierFlags.contains(.option)
                        syncModelEncodingModeIfNeeded()
                        if model.isActivityRunning {
                            onEnqueueExport(quickExport)
                        } else {
                            onStartExport(quickExport)
                        }
                    } label: {
                        Label(
                            exportButtonTitle,
                            systemImage: exportButtonSymbolName
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .help(exportButtonHelpText)
                    .disabled(!model.canRequestClipExport)
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
        .onChange(of: uiClipEncodingMode) { mode in
            if !model.hasVideoTrack && mode != .audioOnly {
                uiClipEncodingMode = .audioOnly
                return
            }
            syncModelEncodingModeIfNeeded()
            if mode == .fast && !model.selectedClipFormat.supportsPassthrough {
                model.selectedClipFormat = .mp4
            }
        }
        .onChange(of: model.clipEncodingMode) { mode in
            if uiClipEncodingMode != mode {
                uiClipEncodingMode = mode
            }
        }
    }
}

extension ClipOutputPanel: Equatable {
    static func == (lhs: ClipOutputPanel, rhs: ClipOutputPanel) -> Bool {
        ObjectIdentifier(lhs.model) == ObjectIdentifier(rhs.model) &&
        lhs.reduceTransparency == rhs.reduceTransparency &&
        lhs.isOptionKeyPressed == rhs.isOptionKeyPressed &&
        lhs.fastClipFormats == rhs.fastClipFormats &&
        lhs.advancedClipFormats == rhs.advancedClipFormats
    }
}
