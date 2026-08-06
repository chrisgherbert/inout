import Combine
import Foundation
import InOutCore

final class WorkspaceViewModel: ObservableObject {}

@main
struct TimecodePresetSmokeTest {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("in-out-timecode-presets-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("presets.json")
        let suiteName = "in-out-timecode-presets-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated defaults")
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        defaults.set(TimecodeDisplayStyle.minuteFrames.rawValue, forKey: TimecodeDisplayPreferences.legacyDefaultsKey)
        let store = TimecodeDisplayPreferences(fileURL: fileURL, defaults: defaults)
        precondition(
            store.selectedPresetID == TimecodeDisplayPreferences.builtInID(for: .minuteFrames),
            "Legacy enum selections must migrate to built-in preset IDs"
        )
        precondition(store.format == TimecodeDisplayStyle.minuteFrames.format)

        store.duplicate(.frames)
        precondition(store.customPresets.first?.format == TimecodeDisplayStyle.frames.format)
        precondition(store.customPresets.first?.name.contains("Hours:Minutes:Seconds:Frames") == true)

        let firstPreset = TimecodeCustomPreset(
            id: UUID(),
            name: "Review Platform",
            format: TimecodeFormatConfiguration(
                layout: .totalMinutes,
                precision: .frames,
                timeSeparator: .hyphen,
                subsecondSeparator: .period,
                padsFirstComponent: false
            )
        )
        store.save(firstPreset)
        store.duplicate(firstPreset)
        precondition(store.customPresets.count == 3)
        let originalOrder = store.customPresets.map(\.id)
        store.moveCustomPresets(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let reorderedIDs = [originalOrder[2], originalOrder[0], originalOrder[1]]
        precondition(store.customPresets.map(\.id) == reorderedIDs)

        store.selectedPresetID = TimecodeDisplayPreferences.customID(for: firstPreset.id)
        store.setHidden(true, for: .standard)
        precondition(store.isHidden(.standard))

        let reloaded = TimecodeDisplayPreferences(fileURL: fileURL, defaults: defaults)
        precondition(reloaded.customPresets.map(\.id) == reorderedIDs)
        precondition(reloaded.selectedPresetID == TimecodeDisplayPreferences.customID(for: firstPreset.id))
        precondition(reloaded.format == firstPreset.format)
        precondition(reloaded.isHidden(.standard))

        reloaded.delete(firstPreset.id)
        precondition(reloaded.selectedPresetID != TimecodeDisplayPreferences.customID(for: firstPreset.id))
        precondition(reloaded.visiblePresets.contains { $0.id == reloaded.selectedPresetID })

        print("Timecode preset smoke test passed.")
    }
}
