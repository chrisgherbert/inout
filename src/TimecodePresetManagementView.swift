import SwiftUI

struct TimecodePresetManagementView: View {
    @ObservedObject var store: TimecodeDisplayPreferences
    @State private var editorPreset: TimecodeCustomPreset?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsRow("Current format") {
                presetPicker
            }

            Text("The selected preset controls timecodes displayed and copied throughout the app. Timeline ruler labels and transcript export formats remain unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Built In")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 0) {
                ForEach(TimecodeDisplayStyle.allCases) { style in
                    builtInRow(style)
                    if style != TimecodeDisplayStyle.allCases.last {
                        Divider()
                    }
                }
            }

            Text("Frame-based presets use each media file’s source frame rate. Semicolon drop-frame timecode is not currently supported.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text("Custom")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    editorPreset = .newPreset()
                } label: {
                    Label("Add Preset…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if store.customPresets.isEmpty {
                Text("Create named formats for the platforms and tools you use most often.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(store.customPresets) { preset in
                        customRow(preset)
                    }
                    .onMove(perform: store.moveCustomPresets)
                }
                .listStyle(.plain)
                .frame(height: customListHeight)

                Text("Drag custom presets to change their order in the Timecode Format menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !store.errorText.isEmpty {
                Label(store.errorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editorPreset) { preset in
            TimecodePresetEditor(
                preset: preset,
                onCancel: { editorPreset = nil },
                onSave: {
                    store.save($0)
                    editorPreset = nil
                }
            )
        }
    }

    private var presetPicker: some View {
        Picker("Timecode Format", selection: $store.selectedPresetID) {
            if !store.visibleBuiltInPresets.isEmpty {
                Section("Built In") {
                    ForEach(store.visibleBuiltInPresets) { preset in
                        Text(preset.menuTitle).tag(preset.id)
                    }
                }
            }
            if !store.customPresetOptions.isEmpty {
                Section("Custom") {
                    ForEach(store.customPresetOptions) { preset in
                        Text(preset.menuTitle).tag(preset.id)
                    }
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var customListHeight: CGFloat {
        min(280, max(52, CGFloat(store.customPresets.count) * 52))
    }

    private func settingsRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 180, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func builtInRow(_ style: TimecodeDisplayStyle) -> some View {
        let hidden = store.isHidden(style)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(style.title)
                Text(style.notation)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.duplicate(style)
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Duplicate as a custom preset")
            Button {
                store.setHidden(!hidden, for: style)
            } label: {
                Image(systemName: hidden ? "eye.slash" : "eye")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!hidden && !store.canHide(style))
            .help(hidden ? "Show in Timecode Format menu" : "Hide from Timecode Format menu")
        }
        .padding(.vertical, 6)
        .opacity(hidden ? 0.55 : 1)
    }

    private func customRow(_ preset: TimecodeCustomPreset) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                Text(preset.format.notation)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editorPreset = preset
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Edit \(preset.name)")
            Button {
                store.duplicate(preset)
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.plain)
            .help("Duplicate \(preset.name)")
            Button(role: .destructive) {
                store.delete(preset.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Delete \(preset.name)")
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct TimecodePresetEditor: View {
    @State private var draft: TimecodeCustomPreset
    let onCancel: () -> Void
    let onSave: (TimecodeCustomPreset) -> Void

    init(
        preset: TimecodeCustomPreset,
        onCancel: @escaping () -> Void,
        onSave: @escaping (TimecodeCustomPreset) -> Void
    ) {
        _draft = State(initialValue: preset)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Custom Timecode Preset")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Name", text: $draft.name, prompt: Text("Platform or workflow name"))

                Picker("Layout", selection: $draft.format.layout) {
                    ForEach(editableLayouts) { layout in
                        Text(layout.title).tag(layout)
                    }
                }

                if draft.format.layout == .clock {
                    Toggle(
                        "Include hours for media under one hour",
                        isOn: $draft.format.includesHoursForShortMedia
                    )
                }

                Picker("Precision", selection: $draft.format.precision) {
                    ForEach(availablePrecisions) { precision in
                        Text(precision.title).tag(precision)
                    }
                }
                .disabled(draft.format.layout == .frameNumber)

                if usesTimeSeparator {
                    Picker("Time separator", selection: $draft.format.timeSeparator) {
                        ForEach(timeSeparators) { separator in
                            Text(separator.title).tag(separator)
                        }
                    }
                }

                if usesSubsecondSeparator {
                    Picker(subsecondSeparatorLabel, selection: $draft.format.subsecondSeparator) {
                        ForEach(subsecondSeparators) { separator in
                            Text(separator.title).tag(separator)
                        }
                    }
                }

                if draft.format.layout != .frameNumber {
                    Toggle("Pad first component to two digits", isOn: $draft.format.padsFirstComponent)
                }
            }
            .formStyle(.grouped)
            .onChange(of: draft.format.layout) { _, layout in
                if layout == .frameNumber {
                    draft.format.precision = .frames
                } else if draft.format.precision == .frames && layout == .totalSeconds {
                    draft.format.precision = .milliseconds
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Preview")
                    .font(.headline)
                Text("Example position: 5 minutes, 25 seconds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if conditionallyOmitsHours {
                    previewRow("Media under one hour", mediaDuration: 1_800)
                    previewRow("Media one hour or longer", mediaDuration: 4_500)
                } else {
                    previewRow("Formatted timecode", mediaDuration: 1_800)
                }
                Text("Frame previews use 24 fps. In media, frame formats use the source frame rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft.normalized)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private var availablePrecisions: [TimecodeDisplayPrecision] {
        if draft.format.layout == .frameNumber { return [.frames] }
        if draft.format.layout == .totalSeconds { return [.seconds, .milliseconds] }
        return TimecodeDisplayPrecision.allCases
    }

    private var editableLayouts: [TimecodeDisplayLayout] {
        TimecodeDisplayLayout.allCases.filter { $0 != .adaptiveClock }
    }

    private var usesTimeSeparator: Bool {
        [.clock, .adaptiveClock, .totalMinutes].contains(draft.format.layout)
    }

    private var usesSubsecondSeparator: Bool {
        draft.format.layout != .frameNumber && draft.format.precision != .seconds
    }

    private var conditionallyOmitsHours: Bool {
        let format = draft.format.normalized
        return format.layout == .clock && !format.includesHoursForShortMedia
    }

    private var timeSeparators: [TimecodeSeparator] {
        [.colon, .period, .hyphen]
    }

    private var subsecondSeparators: [TimecodeSeparator] {
        draft.format.precision == .milliseconds
            ? [.period, .comma, .colon]
            : [.colon, .period]
    }

    private var subsecondSeparatorLabel: String {
        draft.format.precision == .frames ? "Frame separator" : "Decimal separator"
    }

    private func previewRow(_ label: String, mediaDuration: Double) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatDisplayTimecode(
                325.25,
                style: draft.format,
                frameRate: 24,
                mediaDuration: mediaDuration
            ))
                .font(.body.monospacedDigit())
        }
    }
}
