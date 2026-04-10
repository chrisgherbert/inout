import AVFoundation
import SwiftUI

struct ClipPlayerUtilityRow: View {
    let hasVideoTrack: Bool
    let playheadSeconds: Double
    let totalDurationSeconds: Double
    let playheadCopyFlash: Bool
    let compactZoomDisplayText: String
    let timelineZoomLevelCount: Int
    let onCopyPlayheadTimecode: () -> Void
    let onJumpToStart: () -> Void
    let onJumpToEnd: () -> Void
    let onCaptureFrame: () -> Void
    let onZoomOut: () -> Void
    let onZoomIn: () -> Void
    let onFit: () -> Void
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
        HStack(spacing: 6) {
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
            .controlSize(.small)

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

            Text(formatSeconds(playheadSeconds))
                .font(.caption.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(playheadCopyFlash ? Color.accentColor : Color.primary)
            Text("/")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(formatSeconds(totalDurationSeconds))
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
                in: 0...Double(max(0, timelineZoomLevelCount - 1)),
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

            Text(compactZoomDisplayText)
                .font(.caption.monospacedDigit())
                .frame(width: 34, alignment: .trailing)

            Button("Fit", action: onFit)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var wideLayout: some View {
        HStack(spacing: 14) {
            navigationControls

            Spacer(minLength: 16)

            timecodeReadout

            Spacer(minLength: 16)

            zoomControls
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
            navigationControls

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
        lhs.compactZoomDisplayText == rhs.compactZoomDisplayText &&
        lhs.timelineZoomLevelCount == rhs.timelineZoomLevelCount
    }
}
