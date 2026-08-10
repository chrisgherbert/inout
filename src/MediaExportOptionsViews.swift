import SwiftUI

struct MediaAudioBitrateRow: View {
    @ObservedObject var model: WorkspaceViewModel

    private var bitrateBinding: Binding<Double> {
        Binding(
            get: { Double(model.clipAudioBitrateKbps) },
            set: { model.clipAudioBitrateKbps = Int($0.rounded()) }
        )
    }

    var body: some View {
        HStack {
            Text("Audio bitrate")
                .frame(width: 120, alignment: .leading)
            Slider(value: bitrateBinding, in: 64...320, step: 32)
                .controlSize(.small)
            Text("\(model.clipAudioBitrateKbps) kbps")
                .font(.caption.monospacedDigit())
                .frame(width: 90, alignment: .trailing)
        }
    }
}

struct MediaAudioProcessingOptions: View {
    @ObservedObject var model: WorkspaceViewModel
    @Binding var boostAudio: Bool
    @Binding var addFadeInOut: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle(
                "Boost audio (+\(model.clipAdvancedBoostAmount.rawValue) dB, limit -0.1 dBFS)",
                isOn: $boostAudio
            )
            .toggleStyle(.switch)
            .controlSize(.mini)

            if boostAudio {
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

        Toggle("Add audio fade in/out (0.33s at start/end)", isOn: $addFadeInOut)
            .toggleStyle(.switch)
            .controlSize(.mini)
    }
}

struct AudioOnlyExportOptions: View {
    @ObservedObject var model: WorkspaceViewModel

    var body: some View {
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

            MediaAudioBitrateRow(model: model)

            MediaAudioProcessingOptions(
                model: model,
                boostAudio: $model.clipAudioOnlyBoostAudio,
                addFadeInOut: $model.clipAudioOnlyAddFadeInOut
            )
        }
    }
}

struct AdvancedVideoExportOptions: View {
    @ObservedObject var model: WorkspaceViewModel
    let formats: [ClipFormat]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Format") {
                Picker("Format", selection: $model.selectedClipFormat) {
                    ForEach(formats) { format in
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

            MediaFramingOptionsButton(model: model)

            HStack {
                Text("Video bitrate")
                    .frame(width: 120, alignment: .leading)
                Slider(value: $model.clipVideoBitrateMbps, in: 0.5...20, step: 0.5)
                    .controlSize(.small)
                Text(String(format: "%.1f Mbps", model.clipVideoBitrateMbps))
                    .font(.caption.monospacedDigit())
                    .frame(width: 90, alignment: .trailing)
            }

            MediaAudioBitrateRow(model: model)

            MediaAudioProcessingOptions(
                model: model,
                boostAudio: $model.clipAdvancedBoostAudio,
                addFadeInOut: $model.clipAdvancedAddFadeInOut
            )

            HStack(spacing: 10) {
                Toggle("Auto-generate and burn captions", isOn: $model.clipAdvancedBurnInCaptions)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!model.parakeetTranscriptionAvailable)

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
                    .disabled(!model.parakeetTranscriptionAvailable)
                    .help("Caption style for this export.")
                }

                Spacer(minLength: 0)
            }

            if !model.parakeetTranscriptionAvailable {
                Text("Parakeet helper/model not available in app bundle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
