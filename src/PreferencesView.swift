import SwiftUI
import AppKit

struct PreferencesView: View {
    @ObservedObject var model: WorkspaceViewModel
    @State private var profanityEntry = ""
    @State private var selectedPane: PreferencesPane = .general

    private enum PreferencesPane: String, CaseIterable, Identifiable {
        case general = "General"
        case analyze = "Analyze"
        case clip = "Clip"
        case audio = "Audio"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .analyze: return "waveform.path.ecg"
            case .clip: return "timeline.selection"
            case .audio: return "waveform"
            }
        }
    }

    @ViewBuilder
    private func settingsRow<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 210, alignment: .trailing)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func valueMenuPicker<SelectionValue: Hashable, Content: View>(
        _ title: String,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Picker(title, selection: selection) {
            content()
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func setupCheckRow(_ label: String, available: Bool) -> some View {
        settingsRow(label) {
            HStack(spacing: 8) {
                Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(available ? Color.green : Color.red)
                Text(available ? "Available" : "Missing")
                    .foregroundStyle(available ? Color.green : Color.red)
            }
            .font(.body)
        }
    }

    @ViewBuilder
    private func paneScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var generalPane: some View {
        paneScroll {
            settingsSection("Appearance") {
                settingsRow("Theme") {
                    valueMenuPicker("Theme", selection: $model.appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                }
            }
            Divider()

            settingsSection("Notifications") {
                settingsRow("Completion sound") {
                    HStack(spacing: 8) {
                        valueMenuPicker("Completion Sound", selection: $model.completionSound) {
                            ForEach(CompletionSound.allCases) { sound in
                                Text(sound.displayName).tag(sound)
                            }
                        }

                        Button("Play") {
                            guard let soundName = model.completionSound.soundName,
                                  let sound = NSSound(named: soundName) else { return }
                            sound.play()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.completionSound == .none)
                    }
                }
            }
            Divider()

            settingsSection("Setup Checks") {
                setupCheckRow("ffmpeg", available: model.ffmpegAvailable)
                setupCheckRow("ffprobe", available: model.ffprobeAvailable)
                setupCheckRow("yt-dlp", available: model.ytDLPToolAvailable)
                setupCheckRow("whisper-cli", available: model.whisperCLIAvailable)
                setupCheckRow("Whisper model", available: model.whisperModelAvailable)

                settingsRow("") {
                    Button("Recheck") {
                        model.recheckSetupChecks()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Divider()

            settingsSection("Estimated Size Badge") {
                settingsRow("Warning threshold") {
                    Stepper(value: $model.estimatedSizeWarningThresholdGB, in: 0.04...20.0, step: 0.01) {
                        Text(formatSizeThresholdLabel(gigabytes: model.estimatedSizeWarningThresholdGB))
                            .font(.system(.body, design: .monospaced))
                    }
                    .frame(width: 240, alignment: .leading)
                }

                settingsRow("Danger threshold") {
                    Stepper(value: $model.estimatedSizeDangerThresholdGB, in: 0.05...40.0, step: 0.01) {
                        Text(formatSizeThresholdLabel(gigabytes: model.estimatedSizeDangerThresholdGB))
                            .font(.system(.body, design: .monospaced))
                    }
                    .frame(width: 240, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var analyzePane: some View {
        paneScroll {
            settingsSection("Detection") {
                settingsRow("Silence gap threshold") {
                    Stepper(value: $model.silenceMinDurationSeconds, in: 0.5...5.0, step: 0.5) {
                        Text("\(model.silenceMinDurationLabel)s")
                            .font(.system(.body, design: .monospaced))
                    }
                    .frame(width: 180, alignment: .leading)
                }
            }
            Divider()

            settingsSection("Profanity Words") {
                settingsRow("Words (\(model.selectedProfanityWordsCount))") {
                    VStack(alignment: .leading, spacing: 10) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)],
                            alignment: .leading,
                            spacing: 6
                        ) {
                            ForEach(model.selectedProfanityWordsList, id: \.self) { word in
                                HStack(spacing: 6) {
                                    Text(word)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Button {
                                        model.removeProfanityWord(word)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                            }
                        }

                        HStack(spacing: 8) {
                            TextField("Add word(s)…", text: $profanityEntry)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    model.addProfanityWords(from: profanityEntry)
                                    profanityEntry = ""
                                }
                            Button("Add") {
                                model.addProfanityWords(from: profanityEntry)
                                profanityEntry = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button("Reset") {
                                model.resetProfanityWordsToDefaults()
                                profanityEntry = ""
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var clipPane: some View {
        paneScroll {
            settingsSection("Timeline") {
                settingsRow("Default encoding") {
                    valueMenuPicker("Default Encoding", selection: $model.defaultClipEncodingMode) {
                        ForEach(ClipEncodingMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                }

                settingsRow("Jump interval") {
                    Stepper(value: $model.jumpIntervalSeconds, in: 1...30, step: 1) {
                        Text("\(model.jumpIntervalSeconds)s")
                            .font(.system(.body, design: .monospaced))
                    }
                    .frame(width: 180, alignment: .leading)
                }
            }
            Divider()

            settingsSection("Frame Capture") {
                settingsRow("Save location") {
                    valueMenuPicker("Save Location", selection: $model.frameSaveLocationMode) {
                        ForEach(FrameSaveLocationMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                }

                if model.frameSaveLocationMode == .customFolder {
                    settingsRow("Custom folder") {
                        HStack(spacing: 8) {
                            Text(model.customFrameSaveDirectoryPath.isEmpty ? "Not set" : model.customFrameSaveDirectoryPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(model.customFrameSaveDirectoryPath.isEmpty ? .secondary : .primary)
                            Button("Choose…") {
                                model.chooseCustomFrameSaveDirectory()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            Divider()

            settingsSection("URL Download") {
                settingsRow("Default quality") {
                    valueMenuPicker("Default Quality", selection: $model.urlDownloadPreset) {
                        ForEach(URLDownloadPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                }

                settingsRow("Save location") {
                    valueMenuPicker("Save Location", selection: $model.urlDownloadSaveLocationMode) {
                        ForEach(URLDownloadSaveLocationMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                }

                if model.urlDownloadSaveLocationMode == .customFolder {
                    settingsRow("Custom folder") {
                        HStack(spacing: 8) {
                            Text(model.customURLDownloadDirectoryPath.isEmpty ? "Not set" : model.customURLDownloadDirectoryPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(model.customURLDownloadDirectoryPath.isEmpty ? .secondary : .primary)
                            Button("Choose…") {
                                model.chooseCustomURLDownloadDirectory()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            Divider()

            settingsSection("Advanced Export Filename") {
                settingsRow("Preset") {
                    valueMenuPicker("Preset", selection: $model.advancedClipFilenamePreset) {
                        ForEach(AdvancedFilenamePreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                }

                settingsRow("Preview") {
                    HStack(spacing: 8) {
                        Text(model.advancedClipFilenamePreview)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Reset") {
                            model.resetAdvancedClipFilenameTemplateToDefaults()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            Divider()

            settingsSection("Burned-In Captions") {
                settingsRow("Default style") {
                    valueMenuPicker("Default Style", selection: $model.clipAdvancedCaptionStyle) {
                        ForEach(BurnInCaptionStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                }

                settingsRow("Style notes") {
                    Text(model.clipAdvancedCaptionStyle.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()

            settingsSection("Advanced Audio Boost") {
                settingsRow("Default boost amount") {
                    valueMenuPicker("Default Boost Amount", selection: $model.clipAdvancedBoostAmount) {
                        ForEach(AdvancedBoostAmount.allCases) { amount in
                            Text(amount.label).tag(amount)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var audioPane: some View {
        paneScroll {
            settingsSection("Export") {
                settingsRow("Default MP3 bitrate") {
                    Stepper(value: $model.defaultAudioBitrateKbps, in: 64...320, step: 32) {
                        Text("\(model.defaultAudioBitrateKbps) kbps")
                            .font(.system(.body, design: .monospaced))
                    }
                    .frame(width: 200, alignment: .leading)
                }
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedPane) {
            generalPane
                .tag(PreferencesPane.general)
                .tabItem {
                    Label(PreferencesPane.general.rawValue, systemImage: PreferencesPane.general.symbol)
                }

            analyzePane
                .tag(PreferencesPane.analyze)
                .tabItem {
                    Label(PreferencesPane.analyze.rawValue, systemImage: PreferencesPane.analyze.symbol)
                }

            clipPane
                .tag(PreferencesPane.clip)
                .tabItem {
                    Label(PreferencesPane.clip.rawValue, systemImage: PreferencesPane.clip.symbol)
                }

            audioPane
                .tag(PreferencesPane.audio)
                .tabItem {
                    Label(PreferencesPane.audio.rawValue, systemImage: PreferencesPane.audio.symbol)
                }
        }
        .controlSize(.regular)
        .frame(width: 760, height: 560)
        .onAppear {
            model.recheckSetupChecks()
        }
    }
}
