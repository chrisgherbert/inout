import SwiftUI
import AppKit

struct ClipTimelineControlsPanel<Content: View>: View {
    let reduceTransparency: Bool
    let allowedTimelineZoomLevels: [Double]
    let timelineZoomIndex: Int
    let setTimelineZoomIndex: (Int) -> Void
    let timelineZoom: Double
    let totalDurationSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let playheadSeconds: Double
    let clipStartSeconds: Double
    let clipEndSeconds: Double
    let captureMarkers: [CaptureTimelineMarker]
    let onViewportStartChange: (Double) -> Void
    let content: Content

    init(
        reduceTransparency: Bool,
        allowedTimelineZoomLevels: [Double],
        timelineZoomIndex: Int,
        setTimelineZoomIndex: @escaping (Int) -> Void,
        timelineZoom: Double,
        totalDurationSeconds: Double,
        visibleStartSeconds: Double,
        visibleEndSeconds: Double,
        playheadSeconds: Double,
        clipStartSeconds: Double,
        clipEndSeconds: Double,
        captureMarkers: [CaptureTimelineMarker],
        onViewportStartChange: @escaping (Double) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.reduceTransparency = reduceTransparency
        self.allowedTimelineZoomLevels = allowedTimelineZoomLevels
        self.timelineZoomIndex = timelineZoomIndex
        self.setTimelineZoomIndex = setTimelineZoomIndex
        self.timelineZoom = timelineZoom
        self.totalDurationSeconds = totalDurationSeconds
        self.visibleStartSeconds = visibleStartSeconds
        self.visibleEndSeconds = visibleEndSeconds
        self.playheadSeconds = playheadSeconds
        self.clipStartSeconds = clipStartSeconds
        self.clipEndSeconds = clipEndSeconds
        self.captureMarkers = captureMarkers
        self.onViewportStartChange = onViewportStartChange
        self.content = content()
    }

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
                    .controlSize(.small)
                    let displayZoom = allowedTimelineZoomLevels[timelineZoomIndex]
                    Text("\(Int(displayZoom.rounded()))x")
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                    Button("Fit") {
                        setTimelineZoomIndex(0)
                    }
                    .buttonStyle(.bordered)
                }

                TimelineMiniMapView(
                    totalDurationSeconds: totalDurationSeconds,
                    playheadSeconds: playheadSeconds,
                    clipStartSeconds: clipStartSeconds,
                    clipEndSeconds: clipEndSeconds,
                    visibleStartSeconds: visibleStartSeconds,
                    visibleEndSeconds: visibleEndSeconds,
                    captureMarkers: captureMarkers,
                    onViewportStartChange: onViewportStartChange
                )
                .frame(height: 18)

                TimelineMiniMapRulerView(totalDurationSeconds: totalDurationSeconds)
                    .frame(height: 14)

                content
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

private struct TimelineMiniMapRulerView: View {
    let totalDurationSeconds: Double

    private func label(for seconds: Double) -> String {
        let clamped = max(0, Int(seconds.rounded()))
        let h = clamped / 3600
        let m = (clamped % 3600) / 60
        let s = clamped % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private func x(for seconds: Double, width: CGFloat) -> CGFloat {
        let duration = max(0.001, totalDurationSeconds)
        return CGFloat(min(max(0, seconds / duration), 1.0)) * width
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            // Keep this intentionally sparse and stable.
            let divisions = totalDurationSeconds >= 3600 ? 4 : 3
            let step = max(0.001, totalDurationSeconds / Double(divisions))
            let ticks = (0...divisions).map { Double($0) * step }

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 0.6)
                    .offset(y: 2)

                ForEach(Array(ticks.enumerated()), id: \.offset) { _, seconds in
                    let tickX = x(for: seconds, width: width)
                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.22))
                            .frame(width: 1, height: 4)
                        Text(label(for: seconds))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .offset(x: tickX, y: 0)
                }
            }
        }
    }
}

private struct TimelineMiniMapView: View {
    let totalDurationSeconds: Double
    let playheadSeconds: Double
    let clipStartSeconds: Double
    let clipEndSeconds: Double
    let visibleStartSeconds: Double
    let visibleEndSeconds: Double
    let captureMarkers: [CaptureTimelineMarker]
    let onViewportStartChange: (Double) -> Void
    @State private var isDraggingThumb = false
    @State private var thumbGrabOffsetSeconds: Double = 0

    private func x(for seconds: Double, width: CGFloat) -> CGFloat {
        let duration = max(0.001, totalDurationSeconds)
        let ratio = min(max(0, seconds / duration), 1)
        return ratio * width
    }

    private func seconds(for x: CGFloat, width: CGFloat) -> Double {
        let duration = max(0.001, totalDurationSeconds)
        let clampedX = min(max(0, x), width)
        return Double(clampedX / max(1, width)) * duration
    }

    private func startFromLocationX(_ x: CGFloat, width: CGFloat) -> Double {
        let duration = max(0.001, totalDurationSeconds)
        let visibleDuration = max(0.001, visibleEndSeconds - visibleStartSeconds)
        let maxStart = max(0, duration - visibleDuration)
        guard maxStart > 0 else { return 0 }

        let clampedX = min(max(0, x), width)
        let centerSeconds = Double(clampedX / max(1, width)) * duration
        return min(max(0, centerSeconds - (visibleDuration * 0.5)), maxStart)
    }

    private func clampedStart(_ start: Double) -> Double {
        let duration = max(0.001, totalDurationSeconds)
        let visibleDuration = max(0.001, visibleEndSeconds - visibleStartSeconds)
        let maxStart = max(0, duration - visibleDuration)
        return min(max(0, start), maxStart)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let height = proxy.size.height
            let startX = x(for: min(clipStartSeconds, clipEndSeconds), width: width)
            let endX = x(for: max(clipStartSeconds, clipEndSeconds), width: width)
            let clipWidth = max(1.5, endX - startX)
            let playheadX = x(for: playheadSeconds, width: width)
            let viewStartX = x(for: visibleStartSeconds, width: width)
            let viewEndX = x(for: visibleEndSeconds, width: width)
            let viewWidth = max(1.5, viewEndX - viewStartX)
            let canPan = totalDurationSeconds > (visibleEndSeconds - visibleStartSeconds + 0.0001)
            let markerColor = Color(nsColor: .systemOrange)
            let playheadColor = Color(nsColor: .systemRed)
            let clipColor = Color(nsColor: .controlAccentColor)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.6)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: viewWidth, height: max(8, height - 2))
                    .offset(x: viewStartX, y: 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.primary.opacity(0.28), lineWidth: 0.8)
                            .frame(width: viewWidth, height: max(8, height - 2))
                            .offset(x: viewStartX, y: 1)
                    )

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(clipColor.opacity(0.95))
                    .frame(width: clipWidth, height: 2.5)
                    .offset(x: startX, y: (height / 2) - 1.25)

                ForEach(captureMarkers) { marker in
                    Circle()
                        .fill(markerColor)
                        .frame(width: 5, height: 5)
                        .offset(x: x(for: marker.seconds, width: width) - 2.5, y: (height / 2) - 2.5)
                }

                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .fill(playheadColor)
                    .frame(width: 2.2, height: max(10, height - 3))
                    .offset(x: playheadX - 1.1, y: 1.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard canPan else { return }
                        let pointerSeconds = seconds(for: value.location.x, width: width)
                        if !isDraggingThumb {
                            let isInsideThumb = value.startLocation.x >= viewStartX && value.startLocation.x <= viewEndX
                            if isInsideThumb {
                                isDraggingThumb = true
                                thumbGrabOffsetSeconds = pointerSeconds - visibleStartSeconds
                            } else {
                                isDraggingThumb = false
                                thumbGrabOffsetSeconds = 0
                            }
                        }

                        if isDraggingThumb {
                            onViewportStartChange(clampedStart(pointerSeconds - thumbGrabOffsetSeconds))
                        } else {
                            onViewportStartChange(startFromLocationX(value.location.x, width: width))
                        }
                    }
                    .onEnded { _ in
                        isDraggingThumb = false
                        thumbGrabOffsetSeconds = 0
                    }
            )
        }
    }
}

struct ClipSelectionPanel: View {
    @ObservedObject var model: WorkspaceViewModel
    @Environment(\.undoManager) private var undoManager
    @State private var isTimecodeRowHovered = false
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
        GroupBox {
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
                        HStack(spacing: 6) {
                            Text("Playhead: \(formatSeconds(playheadSeconds))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(playheadCopyFlash ? Color.accentColor : Color.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.accentColor.opacity(playheadCopyFlash ? 0.20 : 0.0))
                                )

                            if isTimecodeRowHovered {
                                Button {
                                    onCopyPlayheadTimecode()
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .help("Copy playhead timecode")
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                                .contextMenu {
                                    Button("Copy Timecode") {
                                        onCopyPlayheadTimecode()
                                    }
                                }
                            }
                        }
                        Spacer()
                        Text("Out: \(formatSeconds(model.clipEndSeconds))")
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, -7)
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.12)) {
                            isTimecodeRowHovered = hovering
                        }
                    }
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
                                .onSubmit { model.commitClipStartText(undoManager: undoManager) }
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
                                .onSubmit { model.commitClipEndText(undoManager: undoManager) }
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
                                .onSubmit { model.commitClipStartText(undoManager: undoManager) }
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
                                .onSubmit { model.commitClipEndText(undoManager: undoManager) }
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
