import AVFoundation
import InOutCore
import SwiftUI

struct MediaFramingOptionsButton: View {
    @ObservedObject var model: WorkspaceViewModel
    @State private var showsPopover = false
    @State private var previewImage: NSImage?
    @State private var previewRequestID = UUID()

    private var summary: String {
        guard model.clipFramingAspectRatio != .original else { return "Original" }
        return "\(model.clipFramingAspectRatio.rawValue) · \(model.clipFramingMode.shortLabel)"
    }

    private var sourceDimensions: MediaFramingDimensions? {
        parsedMediaResolution(model.sourceInfo?.resolution)
    }

    var body: some View {
        LabeledContent("Framing") {
            Button {
                showsPopover.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(summary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: 148)
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                MediaFramingPopoverContent(model: model, previewImage: previewImage)
            }
        }
        .onChange(of: showsPopover) { _, isPresented in
            if isPresented {
                loadPreviewFrame()
            }
        }
        .onAppear {
            normalizeSelectedAspectRatio()
        }
        .onChange(of: model.sourceSessionID) { _, _ in
            previewRequestID = UUID()
            previewImage = nil
            normalizeSelectedAspectRatio()
        }
        .onChange(of: model.sourceInfo?.resolution) { _, _ in
            normalizeSelectedAspectRatio()
        }
        .help("Choose an output aspect ratio and how the picture fits its frame")
    }

    private func loadPreviewFrame() {
        guard let sourceURL = model.sourceURL else { return }
        let requestID = UUID()
        previewRequestID = requestID
        let duration = max(0, model.sourceDurationSeconds)
        let seconds = min(max(0, model.clipPlayheadSeconds), max(0, duration - 0.1))

        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVURLAsset(url: sourceURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 900, height: 900)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
            let requestedTime = CMTime(seconds: seconds, preferredTimescale: 600)
            let cgImage = (try? generator.copyCGImage(at: requestedTime, actualTime: nil))
                ?? (try? generator.copyCGImage(at: .zero, actualTime: nil))
            let image = cgImage.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
            DispatchQueue.main.async {
                guard previewRequestID == requestID, model.sourceURL == sourceURL else { return }
                previewImage = image
            }
        }
    }

    private func normalizeSelectedAspectRatio() {
        guard let sourceDimensions,
              mediaFramingAspectRatioMatchesSource(
                model.clipFramingAspectRatio,
                source: sourceDimensions
              ) else { return }
        model.clipFramingAspectRatio = .original
    }
}

private struct MediaFramingPopoverContent: View {
    @ObservedObject var model: WorkspaceViewModel
    let previewImage: NSImage?

    private var outputDimensions: MediaFramingDimensions? {
        guard let source = parsedMediaResolution(model.sourceInfo?.resolution) else { return nil }
        return mediaFramingOutputDimensions(
            aspectRatio: model.clipFramingAspectRatio,
            source: source,
            maximumShortEdge: model.clipCompatibleMaxResolution.maximumShortEdge
        )
    }

    private var availableAspectRatios: [MediaFramingAspectRatio] {
        mediaFramingAvailableAspectRatios(for: parsedMediaResolution(model.sourceInfo?.resolution))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Framing")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Aspect Ratio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Aspect Ratio", selection: $model.clipFramingAspectRatio) {
                    ForEach(availableAspectRatios) { ratio in
                        Text(ratio.rawValue).tag(ratio)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            MediaFramingPreview(
                image: previewImage,
                aspectRatio: model.clipFramingAspectRatio,
                mode: model.clipFramingMode,
                cropAlignment: model.clipFramingCropAlignment
            )
            .frame(maxWidth: .infinity)

            if model.clipFramingAspectRatio != .original {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Fill Mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(MediaFramingMode.allCases) { mode in
                            MediaFramingModeButton(
                                mode: mode,
                                isSelected: model.clipFramingMode == mode
                            ) {
                                model.clipFramingMode = mode
                            }
                        }
                    }
                    Text(model.clipFramingMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.clipFramingMode == .fill {
                    LabeledContent("Crop Position") {
                        Picker("Crop Position", selection: $model.clipFramingCropAlignment) {
                            ForEach(MediaFramingCropAlignment.allCases) { alignment in
                                Text(alignment.rawValue).tag(alignment)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    .font(.caption)
                }
            }

            Divider()

            HStack {
                if let outputDimensions {
                    Text("Output: \(outputDimensions.width) × \(outputDimensions.height)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if model.clipFramingAspectRatio == .original {
                    Text("The source aspect ratio is unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset") {
                    model.clipFramingAspectRatio = .original
                    model.clipFramingMode = .fit
                    model.clipFramingCropAlignment = .center
                }
                .disabled(
                    model.clipFramingAspectRatio == .original &&
                    model.clipFramingMode == .fit &&
                    model.clipFramingCropAlignment == .center
                )
            }
        }
        .padding(16)
        .frame(width: 410)
    }
}

private struct MediaFramingModeButton: View {
    let mode: MediaFramingMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                MediaFramingDiagram(mode: mode)
                    .frame(height: 42)
                Text(mode.shortLabel)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 5)
            .background(
                isSelected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: isSelected ? 1.2 : 0.6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.rawValue)
        .help(mode.detail)
    }
}

private struct MediaFramingDiagram: View {
    let mode: MediaFramingMode

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(0.72))
            if mode == .blurredBackground {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.30))
                    .blur(radius: 3)
            }
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor.opacity(0.72))
                .aspectRatio(16.0 / 9.0, contentMode: mode == .fill ? .fill : .fit)
                .frame(maxWidth: mode == .fill ? 74 : 54)
                .clipped()
            Path { path in
                path.move(to: CGPoint(x: 10, y: 30))
                path.addLine(to: CGPoint(x: 28, y: 16))
                path.addLine(to: CGPoint(x: 42, y: 27))
                path.addLine(to: CGPoint(x: 56, y: 12))
            }
            .stroke(Color.white.opacity(0.75), lineWidth: 1.4)
        }
        .frame(width: 76, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.28), lineWidth: 0.5))
    }
}

private struct MediaFramingPreview: View {
    let image: NSImage?
    let aspectRatio: MediaFramingAspectRatio
    let mode: MediaFramingMode
    let cropAlignment: MediaFramingCropAlignment

    private var sourceRatio: CGFloat {
        guard let image, image.size.height > 0 else { return 16.0 / 9.0 }
        return image.size.width / image.size.height
    }

    private var destinationRatio: CGFloat {
        CGFloat(aspectRatio.ratio ?? Double(sourceRatio))
    }

    private var imageAlignment: Alignment {
        switch cropAlignment {
        case .center: return .center
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let canvasSize = fittedCanvasSize(in: proxy.size)
            ZStack {
                Color.primary.opacity(0.035)
                previewFrame(size: canvasSize)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.18), lineWidth: 0.6))
                    .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
            }
        }
        .frame(height: 196)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private func previewFrame(size: CGSize) -> some View {
        if let image {
            ZStack {
                Color.black
                if aspectRatio == .original {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size.width, height: size.height)
                } else {
                    switch mode {
                    case .fit:
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: size.width, height: size.height)
                    case .fill:
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height, alignment: imageAlignment)
                            .clipped()
                    case .blurredBackground:
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .blur(radius: 14)
                            .scaleEffect(1.08)
                            .clipped()
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: size.width, height: size.height)
                    }
                }
            }
        } else {
            ZStack {
                Color.black.opacity(0.78)
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func fittedCanvasSize(in availableSize: CGSize) -> CGSize {
        let availableWidth = max(1, availableSize.width)
        let availableHeight = max(1, availableSize.height)
        let availableRatio = availableWidth / availableHeight
        if destinationRatio >= availableRatio {
            return CGSize(width: availableWidth, height: availableWidth / destinationRatio)
        }
        return CGSize(width: availableHeight * destinationRatio, height: availableHeight)
    }
}
