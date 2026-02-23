import SwiftUI
import AppKit

struct ClipTimelineControlsPanel: View {
    let reduceTransparency: Bool
    let allowedTimelineZoomLevels: [Double]
    let timelineZoomIndex: Int
    let setTimelineZoomIndex: (Int) -> Void
    let timelineZoom: Double
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let onViewportStartChange: (Double) -> Void

    var body: some View {
        GroupBox("Timeline Controls") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Zoom")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(timelineZoomIndex) },
                            set: { setTimelineZoomIndex(Int($0.rounded())) }
                        ),
                        in: 0...Double(allowedTimelineZoomLevels.count - 1),
                        step: 1
                    )
                    let displayZoom = allowedTimelineZoomLevels[timelineZoomIndex]
                    Text("\(Int(displayZoom.rounded()))x")
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                    Button("Fit") {
                        setTimelineZoomIndex(0)
                    }
                    .buttonStyle(.bordered)
                }

                if timelineZoom > 1 {
                    TimelineViewportScroller(
                        totalDurationSeconds: totalDurationSeconds,
                        visibleStartSeconds: visibleStartSeconds,
                        visibleEndSeconds: visibleEndSeconds
                    ) { newStart in
                        onViewportStartChange(newStart)
                    }
                    .frame(height: 14)

                    HStack(spacing: 6) {
                        Image(systemName: "hand.draw")
                        Text("Drag viewport or use trackpad scroll to pan")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
    }
}

struct ClipSelectionPanel: View {
    @ObservedObject var model: WorkspaceViewModel
    let isCompactLayout: Bool
    let reduceTransparency: Bool
    let isWaveformLoading: Bool
    let waveformSamples: [Double]
    let allowedTimelineZoomLevels: [Double]
    let timelineZoom: Double
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let playheadVisualSeconds: Double
    let playheadJumpFromSeconds: Double
    let playheadJumpAnimationToken: Int
    let playheadSeconds: Double
    let playheadCopyFlash: Bool
    let isTimelineHovered: Bool
    let onTimelineWidthChanged: (CGFloat) -> Void
    let onSeek: (Double, Bool) -> Void
    let onPlayheadDragEdgePan: (CGFloat, CGFloat) -> Void
    let onPlayheadDragStateChanged: (Bool) -> Void
    let onSetStart: (Double) -> Void
    let onSetEnd: (Double) -> Void
    let onWaveformHoverChanged: (Bool) -> Void
    let onWaveformPointerTimeChanged: (Double?) -> Void
    let onTimelineHoverChanged: (Bool) -> Void
    let onCopyPlayheadTimecode: () -> Void
    let onJumpToStart: () -> Void
    let onJumpToEnd: () -> Void
    let onCaptureFrame: () -> Void

    var body: some View {
        GroupBox("Selection") {
            VStack(alignment: .leading, spacing: 10) {
                if !isCompactLayout && isWaveformLoading {
                    HStack {
                        ProgressView()
                        Text("Generating waveform…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !isCompactLayout && !waveformSamples.isEmpty {
                    WaveformView(
                        sourceSessionID: model.sourceSessionID,
                        samples: waveformSamples,
                        zoomLevel: timelineZoom,
                        renderBuckets: allowedTimelineZoomLevels,
                        startSeconds: model.clipStartSeconds,
                        visualPlayheadSeconds: playheadVisualSeconds,
                        playheadJumpFromSeconds: playheadJumpFromSeconds,
                        playheadJumpAnimationToken: playheadJumpAnimationToken,
                        endSeconds: model.clipEndSeconds,
                        totalDurationSeconds: totalDurationSeconds,
                        visibleStartSeconds: visibleStartSeconds,
                        visibleEndSeconds: visibleEndSeconds,
                        captureMarkers: model.captureTimelineMarkers,
                        highlightedMarkerID: model.highlightedCaptureTimelineMarkerID,
                        highlightedClipBoundary: model.highlightedClipBoundary,
                        captureFrameFlashToken: model.captureFrameFlashToken,
                        quickExportFlashToken: model.quickExportFlashToken,
                        onSeek: onSeek,
                        onPlayheadDragEdgePan: onPlayheadDragEdgePan,
                        onPlayheadDragStateChanged: onPlayheadDragStateChanged,
                        onSetStart: onSetStart,
                        onSetEnd: onSetEnd,
                        onHoverChanged: onWaveformHoverChanged,
                        onPointerTimeChanged: onWaveformPointerTimeChanged
                    )
                    .frame(height: 74)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .padding(.bottom, -6)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { onTimelineWidthChanged(geo.size.width) }
                                .onChange(of: geo.size.width) { width in
                                    onTimelineWidthChanged(width)
                                }
                        }
                    )
                }

                if !isCompactLayout {
                    HStack {
                        Text("In: \(formatSeconds(model.clipStartSeconds))")
                            .font(.caption.monospacedDigit())
                        Spacer()
                        Button {
                            onCopyPlayheadTimecode()
                        } label: {
                            Text("Playhead: \(formatSeconds(playheadSeconds))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(playheadCopyFlash ? Color.accentColor : Color.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.accentColor.opacity(playheadCopyFlash ? 0.20 : 0.0))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Click to copy playhead timecode")
                        .contextMenu {
                            Button("Copy Timecode") {
                                onCopyPlayheadTimecode()
                            }
                        }
                        Spacer()
                        Text("Out: \(formatSeconds(model.clipEndSeconds))")
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, -7)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Text("In")
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .leading)
                            TextField("00:00:00.000", text: $model.clipStartText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 140)
                                .onSubmit { model.commitClipStartText() }
                            Button("Set In") { onSetStart(playheadSeconds) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }

                        HStack(spacing: 8) {
                            Text("Out")
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .leading)
                            TextField("00:00:00.000", text: $model.clipEndText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 140)
                                .onSubmit { model.commitClipEndText() }
                            Button("Set Out") { onSetEnd(playheadSeconds) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .font(.caption)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("In")
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .leading)
                            TextField("00:00:00.000", text: $model.clipStartText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onSubmit { model.commitClipStartText() }
                            Button("Set In") { onSetStart(playheadSeconds) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }

                        HStack(spacing: 8) {
                            Text("Out")
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .leading)
                            TextField("00:00:00.000", text: $model.clipEndText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onSubmit { model.commitClipEndText() }
                            Button("Set Out") { onSetEnd(playheadSeconds) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .font(.caption)
                }

                if !isCompactLayout {
                    HStack {
                        Text("Duration: \(formatSeconds(model.clipDurationSeconds))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        ControlGroup {
                            Button(action: onJumpToStart) {
                                Image(systemName: "backward.end.fill")
                            }
                            .help("Jump to Clip Start")
                            .accessibilityLabel("Jump to Clip Start")

                            Button(action: onJumpToEnd) {
                                Image(systemName: "forward.end.fill")
                            }
                            .help("Jump to Clip End")
                            .accessibilityLabel("Jump to Clip End")
                        }
                        .controlSize(.mini)
                        .opacity(isTimelineHovered ? 0.95 : 0.0)
                        .allowsHitTesting(isTimelineHovered)
                        .animation(.easeOut(duration: 0.15), value: isTimelineHovered)

                        if model.hasVideoTrack {
                            Button(action: onCaptureFrame) {
                                Label("Capture Frame", systemImage: "camera")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Save a PNG frame at the current playhead")
                            .labelStyle(.titleAndIcon)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.leading, 2)
                        }
                    }
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
            .onHover(perform: onTimelineHoverChanged)
        }
    }
}

struct ClipOutputPanel: View {
    @ObservedObject var model: WorkspaceViewModel
    let reduceTransparency: Bool
    let isOptionKeyPressed: Bool
    let fastClipFormats: [ClipFormat]
    let advancedClipFormats: [ClipFormat]
    let onStartExport: (_ quickExport: Bool) -> Void

    var body: some View {
        GroupBox("Output") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $model.clipEncodingMode) {
                        if model.hasVideoTrack {
                            Label("Fast", systemImage: "bolt.fill").tag(ClipEncodingMode.fast)
                            Label("Advanced", systemImage: "slider.horizontal.3").tag(ClipEncodingMode.compressed)
                        }
                        Label("Audio Only", systemImage: "waveform").tag(ClipEncodingMode.audioOnly)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)

                    Text(
                        model.clipEncodingMode == .fast
                        ? "Fast mode uses passthrough copy with minimal processing."
                        : model.clipEncodingMode == .compressed
                            ? "Advanced mode unlocks codec, container, resolution, and bitrate options."
                            : "Audio Only exports only audio from the selected clip range."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Divider()

                    if model.clipEncodingMode == .audioOnly {
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

                        Toggle("Boost audio (+10 dB, limit -0.1 dBFS)", isOn: $model.clipAudioOnlyBoostAudio)
                            .toggleStyle(.switch)
                            .controlSize(.mini)

                        Toggle("Add audio fade in/out (0.33s at start/end)", isOn: $model.clipAudioOnlyAddFadeInOut)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    } else {
                        LabeledContent("Format") {
                            Picker("Format", selection: $model.selectedClipFormat) {
                                if model.clipEncodingMode == .fast {
                                    ForEach(fastClipFormats) { format in
                                        Text(format.rawValue).tag(format)
                                    }
                                } else {
                                    ForEach(advancedClipFormats) { format in
                                        Text(format.rawValue).tag(format)
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 148)
                        }
                    }

                    if model.clipEncodingMode == .compressed {
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
                            Slider(value: $model.clipVideoBitrateMbps, in: 2...20, step: 0.5)
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

                        Toggle("Boost audio (+10 dB, limit -0.1 dBFS)", isOn: $model.clipAdvancedBoostAudio)
                            .toggleStyle(.switch)
                            .controlSize(.mini)

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
                    if model.clipEncodingMode == .audioOnly, model.clipAudioOnlyFormat != .wav {
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
                    } else if model.clipEncodingMode == .compressed {
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
                        onStartExport(NSEvent.modifierFlags.contains(.option))
                    } label: {
                        Label(
                            model.isExporting
                                ? "Exporting…"
                                : (isOptionKeyPressed ? "Quick Export Clip" : "Export Clip"),
                            systemImage: "film.stack"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Export Clip. Option-click for Quick Export (no save dialog).")
                    .disabled(!model.canExportClip)
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
    }
}
