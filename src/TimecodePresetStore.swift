import Foundation

struct TimecodeCustomPreset: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var format: TimecodeFormatConfiguration

    static func newPreset() -> TimecodeCustomPreset {
        TimecodeCustomPreset(
            id: UUID(),
            name: "",
            format: TimecodeDisplayStyle.precise.format
        )
    }

    var normalized: TimecodeCustomPreset {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.format = format.normalized
        return result
    }
}

struct TimecodePresetOption: Identifiable, Equatable {
    let id: String
    let name: String
    let format: TimecodeFormatConfiguration
    let builtInStyle: TimecodeDisplayStyle?

    var isBuiltIn: Bool { builtInStyle != nil }
    var menuTitle: String { "\(name) (\(format.notation))" }
}

private struct TimecodePresetFile: Codable {
    let version: Int
    let customPresets: [TimecodeCustomPreset]
    let hiddenBuiltInStyleIDs: [String]
}

@MainActor
final class TimecodeDisplayPreferences: ObservableObject {
    static let shared = TimecodeDisplayPreferences()
    static let legacyDefaultsKey = "prefs.timecodeDisplayStyle"
    static let selectedPresetDefaultsKey = "prefs.selectedTimecodePreset"

    @Published private(set) var customPresets: [TimecodeCustomPreset] = []
    @Published private(set) var hiddenBuiltInStyles: Set<TimecodeDisplayStyle> = []
    @Published private(set) var errorText = ""
    @Published var selectedPresetID: String {
        didSet {
            defaults.set(selectedPresetID, forKey: Self.selectedPresetDefaultsKey)
        }
    }

    private let fileURL: URL
    private let defaults: UserDefaults

    init(fileURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.defaults = defaults

        if let storedPresetID = defaults.string(forKey: Self.selectedPresetDefaultsKey) {
            selectedPresetID = storedPresetID
        } else {
            let legacyStyle = defaults.string(forKey: Self.legacyDefaultsKey)
                .flatMap(TimecodeDisplayStyle.init(rawValue:)) ?? .precise
            selectedPresetID = Self.builtInID(for: legacyStyle)
        }
        load()
        ensureValidSelection()
        defaults.set(selectedPresetID, forKey: Self.selectedPresetDefaultsKey)
    }

    var builtInPresets: [TimecodePresetOption] {
        TimecodeDisplayStyle.allCases.map { style in
            TimecodePresetOption(
                id: Self.builtInID(for: style),
                name: style.title,
                format: style.format,
                builtInStyle: style
            )
        }
    }

    var visibleBuiltInPresets: [TimecodePresetOption] {
        builtInPresets.filter { option in
            guard let style = option.builtInStyle else { return false }
            return !hiddenBuiltInStyles.contains(style)
        }
    }

    var customPresetOptions: [TimecodePresetOption] {
        customPresets.map { preset in
            TimecodePresetOption(
                id: Self.customID(for: preset.id),
                name: preset.name,
                format: preset.format,
                builtInStyle: nil
            )
        }
    }

    var visiblePresets: [TimecodePresetOption] {
        visibleBuiltInPresets + customPresetOptions
    }

    var selectedPreset: TimecodePresetOption {
        preset(withID: selectedPresetID) ?? builtInPresets[0]
    }

    var format: TimecodeFormatConfiguration {
        selectedPreset.format
    }

    func select(_ presetID: String) {
        guard preset(withID: presetID) != nil else { return }
        selectedPresetID = presetID
    }

    func isHidden(_ style: TimecodeDisplayStyle) -> Bool {
        hiddenBuiltInStyles.contains(style)
    }

    func canHide(_ style: TimecodeDisplayStyle) -> Bool {
        isHidden(style) || visiblePresets.count > 1
    }

    func setHidden(_ hidden: Bool, for style: TimecodeDisplayStyle) {
        guard !hidden || canHide(style) else { return }
        if hidden {
            hiddenBuiltInStyles.insert(style)
        } else {
            hiddenBuiltInStyles.remove(style)
        }
        persist()
        ensureValidSelection()
    }

    func save(_ preset: TimecodeCustomPreset) {
        let normalized = preset.normalized
        guard !normalized.name.isEmpty else { return }
        if let index = customPresets.firstIndex(where: { $0.id == normalized.id }) {
            customPresets[index] = normalized
        } else {
            customPresets.append(normalized)
        }
        persist()
    }

    func duplicate(_ preset: TimecodeCustomPreset) {
        var copy = preset
        copy.id = UUID()
        copy.name = uniqueCopyName(for: preset.name)
        save(copy)
    }

    func duplicate(_ style: TimecodeDisplayStyle) {
        save(
            TimecodeCustomPreset(
                id: UUID(),
                name: uniqueCopyName(for: style.title),
                format: style.format
            )
        )
    }

    func delete(_ id: UUID) {
        customPresets.removeAll { $0.id == id }
        persist()
        ensureValidSelection()
    }

    func moveCustomPresets(fromOffsets: IndexSet, toOffset: Int) {
        let sourceIndexes = fromOffsets.filter(customPresets.indices.contains).sorted()
        guard !sourceIndexes.isEmpty else { return }
        let moving = sourceIndexes.map { customPresets[$0] }
        let sourceIndexSet = Set(sourceIndexes)
        var remaining = customPresets.enumerated().compactMap { index, preset in
            sourceIndexSet.contains(index) ? nil : preset
        }
        let removedBeforeDestination = sourceIndexes.lazy.filter { $0 < toOffset }.count
        let insertionIndex = min(remaining.count, max(0, toOffset - removedBeforeDestination))
        remaining.insert(contentsOf: moving, at: insertionIndex)
        customPresets = remaining
        persist()
    }

    private func preset(withID id: String) -> TimecodePresetOption? {
        (builtInPresets + customPresetOptions).first { $0.id == id }
    }

    private func ensureValidSelection() {
        if visiblePresets.isEmpty {
            hiddenBuiltInStyles.remove(.precise)
            persist()
        }
        guard preset(withID: selectedPresetID) == nil ||
                hiddenSelectedBuiltInStyle != nil else { return }
        selectedPresetID = visiblePresets.first?.id ?? Self.builtInID(for: .precise)
    }

    private var hiddenSelectedBuiltInStyle: TimecodeDisplayStyle? {
        guard selectedPresetID.hasPrefix("builtIn:"),
              let rawValue = selectedPresetID.split(separator: ":").last,
              let style = TimecodeDisplayStyle(rawValue: String(rawValue)),
              hiddenBuiltInStyles.contains(style) else { return nil }
        return style
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try JSONDecoder().decode(TimecodePresetFile.self, from: data)
            guard file.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            customPresets = file.customPresets.map(\.normalized)
            hiddenBuiltInStyles = Set(file.hiddenBuiltInStyleIDs.compactMap(TimecodeDisplayStyle.init(rawValue:)))
            errorText = ""
        } catch {
            errorText = "Timecode presets couldn’t be loaded: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let file = TimecodePresetFile(
                version: 1,
                customPresets: customPresets,
                hiddenBuiltInStyleIDs: hiddenBuiltInStyles.map(\.rawValue).sorted()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: fileURL, options: .atomic)
            errorText = ""
        } catch {
            errorText = "Timecode presets couldn’t be saved: \(error.localizedDescription)"
        }
    }

    private func uniqueCopyName(for name: String) -> String {
        let existing = Set(customPresets.map { $0.name.lowercased() })
        let base = "\(name) Copy"
        guard existing.contains(base.lowercased()) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    static func builtInID(for style: TimecodeDisplayStyle) -> String {
        "builtIn:\(style.rawValue)"
    }

    static func customID(for id: UUID) -> String {
        "custom:\(id.uuidString)"
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("In-Out", isDirectory: true)
            .appendingPathComponent("timecode-presets.json")
    }
}
