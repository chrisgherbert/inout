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
        ZStack {
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
                .controlSize(.mini)

                if hasVideoTrack {
                    Button(action: onCaptureFrame) {
                        Label("Capture Frame", systemImage: "camera")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Save a PNG frame at the current playhead")
                    .accessibilityLabel("Capture Frame")
                }

                Spacer()
            }

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

            HStack {
                Spacer()

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
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}
