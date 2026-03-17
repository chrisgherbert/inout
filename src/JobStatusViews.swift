import SwiftUI
import AppKit

struct StatusFooterStripView: View {
    @ObservedObject var activity: ActivityPresentationModel
    let queuedJobs: [QueuedClipExport]
    let isAnalyzing: Bool
    let isExporting: Bool
    let isActivityRunning: Bool
    let outputURL: URL?
    let stopCurrentActivity: () -> Void
    let revealOutput: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var stateColor: Color {
        switch activity.lastActivityState {
        case .idle:
            return .secondary
        case .running:
            return .accentColor
        case .success:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }

    private var footerStateLabel: String {
        guard activity.lastActivityState == .running else {
            return activity.lastResultLabel
        }

        let orderedJobs = queuedJobs.sorted(by: { $0.createdAt < $1.createdAt })
        guard !orderedJobs.isEmpty else { return activity.lastResultLabel }

        if let runningIndex = orderedJobs.firstIndex(where: { $0.status == .running }) {
            return "Running (\(runningIndex + 1)/\(orderedJobs.count) tasks)"
        }

        return "Running (1/\(orderedJobs.count) tasks)"
    }

    @ViewBuilder
    private var stateIconView: some View {
        if #available(macOS 14.0, *), !reduceMotion {
            Image(systemName: activity.lastResultIconName)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, options: isActivityRunning ? .repeating : .default, value: isActivityRunning)
        } else {
            Image(systemName: activity.lastResultIconName)
        }
    }

    var body: some View {
        HStack(spacing: 14) {
                HStack(spacing: 8) {
                    stateIconView
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(stateColor)
                        .frame(width: 20, height: 20, alignment: .center)
                Text(footerStateLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 140, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(activityText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let progress = activityProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Group {
                    if isActivityRunning {
                        Button(role: .destructive) {
                            stopCurrentActivity()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    } else if outputURL != nil {
                        Button("Show in Finder") {
                            revealOutput()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            adaptiveContainerFill(
                material: .regularMaterial,
                fallback: Color(nsColor: .windowBackgroundColor),
                reduceTransparency: reduceTransparency
            )
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(height: 0.5)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: activity.lastActivityState)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isActivityRunning)
    }

    private var activityProgress: Double? {
        if isAnalyzing { return activity.analyzeProgress }
        if isExporting { return activity.exportProgress }
        return nil
    }

    private var activityText: String {
        if isAnalyzing { return activity.analyzeStatusText }
        if isExporting { return activity.exportStatusText }
        return activity.uiMessage
    }
}

struct JobsPopoverView: View {
    @ObservedObject var model: WorkspaceViewModel
    @State private var hoveredJobID: UUID?

    private var sortedQueuedJobs: [QueuedClipExport] {
        model.queuedJobs.sorted(by: { $0.createdAt > $1.createdAt })
    }

    private var hasCompletedJobs: Bool {
        model.queuedJobs.contains(where: {
            $0.status == .completed || $0.status == .failed || $0.status == .cancelled
        })
    }

    private func queueStatusIconName(_ status: ClipExportQueueStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private func queueStatusColor(_ status: ClipExportQueueStatus) -> Color {
        switch status {
        case .queued: return .secondary
        case .running: return .accentColor
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    private func queueStatusLabel(_ status: ClipExportQueueStatus) -> String {
        switch status {
        case .queued: return "Queued"
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Jobs", systemImage: "list.bullet.rectangle.portrait")
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    model.clearCompletedQueuedJobs()
                } label: {
                    Label("Clear Completed", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!hasCompletedJobs)
            }

            Divider()

            if sortedQueuedJobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No jobs yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sortedQueuedJobs.enumerated()), id: \.element.id) { index, item in
                            HStack(alignment: .center, spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 8) {
                                        Image(systemName: queueStatusIconName(item.status))
                                            .foregroundStyle(queueStatusColor(item.status))
                                            .frame(width: 12)
                                        Text(item.summary)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                    }

                                    let detail = [item.subtitle, item.message].compactMap { value -> String? in
                                        guard let value, !value.isEmpty else { return nil }
                                        return value
                                    }.joined(separator: " • ")
                                    if !detail.isEmpty {
                                        Text(detail)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer(minLength: 8)

                                HStack(spacing: 6) {
                                    Text(queueStatusLabel(item.status))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    if item.status == .queued {
                                        Button("Cancel") {
                                            model.removeQueuedJob(item.id)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    } else if item.status == .failed || item.status == .cancelled {
                                        Button("Retry") {
                                            model.retryQueuedJob(item.id)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    } else if item.status == .completed, let outputURL = item.outputURL {
                                        Button {
                                            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                        } label: {
                                            Image(systemName: "magnifyingglass")
                                        }
                                        .help("Show in Finder")
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                }
                                .frame(width: 180, alignment: .trailing)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .frame(minHeight: 34)
                            .background(
                                Color.accentColor.opacity(hoveredJobID == item.id ? 0.08 : 0.0)
                            )
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering {
                                    hoveredJobID = item.id
                                } else if hoveredJobID == item.id {
                                    hoveredJobID = nil
                                }
                            }

                            if index < sortedQueuedJobs.count - 1 {
                                Divider()
                                    .opacity(0.5)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 560, height: 320, alignment: .topLeading)
    }
}
