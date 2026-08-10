import AVFoundation
import SwiftUI

struct ClipPlayerUtilityRow: View {
    @Environment(\.timecodeDisplayStyle) private var timecodeDisplayStyle
    @Environment(\.timecodeFrameRate) private var timecodeFrameRate
    let hasVideoTrack: Bool
    let playheadSeconds: Double
    let totalDurationSeconds: Double
    let playheadCopyFlash: Bool
    let timelineZoomLevels: [Double]
    let timelineZoomIndex: Int
    let canSuggestMarkers: Bool
    let isSuggestingMarkers: Bool
    let isTranscribingForMarkers: Bool
    let onCopyPlayheadTimecode: () -> Void
    let onNavigatePrevious: () -> Void
    let onNavigateNext: () -> Void
    let onCaptureFrame: () -> Void
    let onSuggestMarkers: () -> Void
    let onZoomOut: () -> Void
    let onZoomIn: () -> Void
    let timelineZoomIndexBinding: Binding<Double>

    @State private var isPlayerTimecodeHovered = false
    @State private var isZoomOutHovered = false
    @State private var isZoomInHovered = false

    var body: some View {
        let _ = PlayheadDiagnostics.shared.noteUtilityRowBodyEvaluation()
        ViewThatFits(in: .horizontal) {
            wideLayout
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .center)

            splitLayout
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)

            compactLayout
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
    }

    private var navigationControls: some View {
        HStack(spacing: 8) {
            transportControls

            Divider()
                .frame(height: 16)

            actionControls
            aiSuggestionsButton
        }
    }

    private var transportControls: some View {
        ControlGroup {
            Button(action: onNavigatePrevious) {
                Image(systemName: "backward.end.fill")
            }
            .help("Previous Marker or Clip Edge (Up Arrow)")
            .accessibilityLabel("Previous Marker or Clip Edge")

            Button(action: onNavigateNext) {
                Image(systemName: "forward.end.fill")
            }
            .help("Next Marker or Clip Edge (Down Arrow)")
            .accessibilityLabel("Next Marker or Clip Edge")
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var actionControls: some View {
        HStack(spacing: 6) {
            if hasVideoTrack {
                Button(action: onCaptureFrame) {
                    Label("Capture Frame", systemImage: "camera")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Save a PNG frame at the current playhead")
                .accessibilityLabel("Capture Frame")
            }
        }
    }

    private var aiSuggestionsButton: some View {
        Button(action: onSuggestMarkers) {
            Label(
                isTranscribingForMarkers
                    ? "Transcribing…"
                    : (isSuggestingMarkers ? "Analyzing…" : "AI Suggestions…"),
                systemImage: "sparkles"
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!canSuggestMarkers || isSuggestingMarkers || isTranscribingForMarkers)
        .help(
            canSuggestMarkers
                ? "Generate editorial suggestions, creating a transcript first if needed"
                : "AI Suggestions requires an audio transcript"
        )
        .accessibilityLabel("AI Suggestions")
    }

    private var compactNavigationControls: some View {
        ViewThatFits(in: .horizontal) {
            navigationControls
                .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    transportControls
                    actionControls
                }
                aiSuggestionsButton
            }
        }
    }

    private var timecodeReadout: some View {
        HStack(spacing: 6) {
            Button(action: onCopyPlayheadTimecode) {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("Copy playhead timecode")
            .opacity(isPlayerTimecodeHovered ? 1.0 : 0.0)
            .allowsHitTesting(isPlayerTimecodeHovered)
            .accessibilityHidden(!isPlayerTimecodeHovered)
            .contextMenu {
                Button("Copy Timecode", action: onCopyPlayheadTimecode)
            }

            Text(formatDisplayTimecode(
                playheadSeconds,
                style: timecodeDisplayStyle,
                frameRate: timecodeFrameRate,
                mediaDuration: totalDurationSeconds
            ))
                .font(.caption.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(playheadCopyFlash ? Color.accentColor : Color.primary)
            Text("/")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(formatDisplayTimecode(
                totalDurationSeconds,
                style: timecodeDisplayStyle,
                frameRate: timecodeFrameRate,
                mediaDuration: totalDurationSeconds
            ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .onHover { hovering in
            isPlayerTimecodeHovered = hovering
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button(action: onZoomOut) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isZoomOutHovered ? 0.10 : 0.0))
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Zoom Out")
            .onHover { hovering in
                isZoomOutHovered = hovering
            }

            Slider(
                value: timelineZoomIndexBinding,
                in: 0...Double(max(0, timelineZoomLevels.count - 1)),
                step: 1
            )
            .controlSize(.regular)
            .frame(width: 104)

            Button(action: onZoomIn) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isZoomInHovered ? 0.10 : 0.0))
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Zoom In")
            .onHover { hovering in
                isZoomInHovered = hovering
            }

            Picker("Timeline Zoom", selection: timelineZoomIndexBinding) {
                ForEach(Array(timelineZoomLevels.indices), id: \.self) { index in
                    Text(zoomLabel(at: index))
                        .tag(Double(index))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help("Timeline Zoom")
        }
    }

    private func zoomLabel(at index: Int) -> String {
        guard index > 0, timelineZoomLevels.indices.contains(index) else {
            return "Fit"
        }
        let zoom = timelineZoomLevels[index]
        if abs(zoom.rounded() - zoom) < 0.001 {
            return "\(Int(zoom.rounded()))×"
        }
        return String(format: "%.1f×", zoom)
    }

    private var wideLayout: some View {
        HStack(spacing: 0) {
            navigationControls
                .frame(width: 310, alignment: .leading)
            timecodeReadout
            zoomControls
                .frame(width: 310, alignment: .trailing)
        }
    }

    private var splitLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                navigationControls
                Spacer(minLength: 16)
                timecodeReadout
            }

            HStack {
                Spacer(minLength: 0)
                zoomControls
            }
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            compactNavigationControls

            timecodeReadout

            HStack {
                Spacer(minLength: 0)
                zoomControls
            }
        }
    }
}

extension ClipPlayerUtilityRow: Equatable {
    static func == (lhs: ClipPlayerUtilityRow, rhs: ClipPlayerUtilityRow) -> Bool {
        lhs.hasVideoTrack == rhs.hasVideoTrack &&
        lhs.playheadSeconds == rhs.playheadSeconds &&
        lhs.totalDurationSeconds == rhs.totalDurationSeconds &&
            lhs.playheadCopyFlash == rhs.playheadCopyFlash &&
            lhs.timelineZoomLevels == rhs.timelineZoomLevels &&
            lhs.timelineZoomIndex == rhs.timelineZoomIndex &&
            lhs.canSuggestMarkers == rhs.canSuggestMarkers &&
            lhs.isSuggestingMarkers == rhs.isSuggestingMarkers &&
            lhs.isTranscribingForMarkers == rhs.isTranscribingForMarkers
    }
}
