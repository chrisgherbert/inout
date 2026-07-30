import Foundation

private struct SmartMarkerCustomRecipeFile: Codable {
    let version: Int
    let recipes: [SmartMarkerCustomRecipe]
    let hiddenBuiltInRecipeIDs: [String]?
}

@MainActor
final class SmartMarkerRecipeStore: ObservableObject {
    static let shared = SmartMarkerRecipeStore()

    @Published private(set) var customRecipes: [SmartMarkerCustomRecipe] = []
    @Published private(set) var hiddenBuiltInRecipes: Set<SmartMarkerRecipe> = []
    @Published private(set) var errorText = ""

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    func save(_ recipe: SmartMarkerCustomRecipe) {
        let normalized = recipe.normalized
        guard !normalized.name.isEmpty, !normalized.instructions.isEmpty else { return }
        if let index = customRecipes.firstIndex(where: { $0.id == normalized.id }) {
            customRecipes[index] = normalized
        } else {
            customRecipes.append(normalized)
        }
        customRecipes.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        persist()
    }

    func duplicate(_ recipe: SmartMarkerCustomRecipe) {
        var copy = recipe
        copy.id = UUID()
        copy.name = uniqueCopyName(for: recipe.name)
        save(copy)
    }

    func delete(_ id: UUID) {
        customRecipes.removeAll { $0.id == id }
        persist()
    }

    func isHidden(_ recipe: SmartMarkerRecipe) -> Bool {
        hiddenBuiltInRecipes.contains(recipe)
    }

    func setHidden(_ hidden: Bool, for recipe: SmartMarkerRecipe) {
        if hidden {
            hiddenBuiltInRecipes.insert(recipe)
        } else {
            hiddenBuiltInRecipes.remove(recipe)
        }
        persist()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try JSONDecoder().decode(SmartMarkerCustomRecipeFile.self, from: data)
            guard file.version == 1 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            customRecipes = file.recipes.map(\.normalized).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            hiddenBuiltInRecipes = Set(
                (file.hiddenBuiltInRecipeIDs ?? []).compactMap(SmartMarkerRecipe.init(rawValue:))
            )
            errorText = ""
        } catch {
            errorText = "Custom analyses couldn’t be loaded: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let file = SmartMarkerCustomRecipeFile(
                version: 1,
                recipes: customRecipes,
                hiddenBuiltInRecipeIDs: hiddenBuiltInRecipes
                    .map(\.rawValue)
                    .sorted()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: fileURL, options: .atomic)
            errorText = ""
        } catch {
            errorText = "Custom analyses couldn’t be saved: \(error.localizedDescription)"
        }
    }

    private func uniqueCopyName(for name: String) -> String {
        let existing = Set(customRecipes.map { $0.name.lowercased() })
        let base = "\(name) Copy"
        guard existing.contains(base.lowercased()) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("In-Out", isDirectory: true)
            .appendingPathComponent("custom-analysis-recipes.json")
    }
}
