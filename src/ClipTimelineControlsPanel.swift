import SwiftUI
import AppKit
import AVFoundation

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
                .padding(.horizontal, 6)
                .padding(.top, 7)

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

    var body: some View {
        let _ = PlayheadDiagnostics.shared.noteMiniMapBodyEvaluation()
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let height = proxy.size.height
            let trackTop: CGFloat = 1
            let trackHeight = max(8, height - 2)
            let startX = x(for: min(clipStartSeconds, clipEndSeconds), width: width)
            let endX = x(for: max(clipStartSeconds, clipEndSeconds), width: width)
            let clipWidth = max(1.5, endX - startX)
            let playheadX = x(for: playheadSeconds, width: width)
            let viewStartX = x(for: visibleStartSeconds, width: width)
            let viewEndX = x(for: visibleEndSeconds, width: width)
            let viewWidth = max(1.5, viewEndX - viewStartX)
            let divisions = totalDurationSeconds >= 3600 ? 4 : 3
            let step = max(0.001, totalDurationSeconds / Double(divisions))
            let ticks = (0...divisions).map { Double($0) * step }
            let canPan = totalDurationSeconds > (visibleEndSeconds - visibleStartSeconds + 0.0001)
            let markerColor = Color(nsColor: .systemOrange)
            let playheadColor = Color(nsColor: .systemRed)
            let clipColor = Color(nsColor: .controlAccentColor)
            let tickLabelWidth: CGFloat = 58

            ZStack(alignment: .leading) {
                ForEach(Array(ticks.enumerated()), id: \.offset) { index, seconds in
                    let tickX = x(for: seconds, width: width)
                    let isFirstTick = index == 0
                    let isLastTick = index == ticks.count - 1
                    let tickAlignment: Alignment = isFirstTick ? .leading : (isLastTick ? .trailing : .center)
                    let tickAnchorOffset: CGFloat = isFirstTick ? 0 : (isLastTick ? tickLabelWidth : tickLabelWidth / 2)

                    VStack(spacing: 1) {
                        Text(label(for: seconds))
                            .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: tickLabelWidth, alignment: tickAlignment)
                        Rectangle()
                            .fill(Color.primary.opacity(0.22))
                            .frame(width: 1, height: 3)
                            .frame(width: tickLabelWidth, alignment: tickAlignment)
                    }
                    .offset(x: tickX - tickAnchorOffset, y: -6)
                    .allowsHitTesting(false)
                }

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: trackHeight)
                    .offset(y: trackTop)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.6)
                    .frame(height: trackHeight)
                    .offset(y: trackTop)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: viewWidth, height: max(8, trackHeight - 2))
                    .offset(x: viewStartX, y: trackTop + 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.primary.opacity(0.28), lineWidth: 0.8)
                            .frame(width: viewWidth, height: max(8, trackHeight - 2))
                            .offset(x: viewStartX, y: trackTop + 1)
                    )

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(clipColor.opacity(0.95))
                    .frame(width: clipWidth, height: 2.5)
                    .offset(x: startX, y: trackTop + (trackHeight / 2) - 1.25)

                ForEach(captureMarkers) { marker in
                    Circle()
                        .fill(markerColor)
                        .frame(width: 5, height: 5)
                        .offset(x: x(for: marker.seconds, width: width) - 2.5, y: trackTop + (trackHeight / 2) - 2.5)
                }

                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .fill(playheadColor)
                    .frame(width: 2.2, height: max(10, trackHeight - 1))
                    .offset(x: playheadX - 1.1, y: trackTop + 0.5)
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
