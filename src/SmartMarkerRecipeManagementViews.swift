import SwiftUI

struct SmartMarkerRecipeManagementView: View {
    @ObservedObject var store: SmartMarkerRecipeStore
    @State private var editorRecipe: SmartMarkerCustomRecipe?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                ForEach(SmartMarkerRecipe.allCases) { recipe in
                    builtInRecipeRow(recipe)
                    if recipe.id != SmartMarkerRecipe.allCases.last?.id {
                        Divider()
                    }
                }
            }

            Divider()

            HStack {
                Text("Custom")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    editorRecipe = .newRecipe()
                } label: {
                    Label("Add Analysis…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if store.customRecipes.isEmpty {
                Text("Create reusable analyses with custom instructions and standard marker, range, or text output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.customRecipes) { recipe in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recipe.name)
                                Text(recipe.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            outputBadge(recipe.outputKind)
                            Button {
                                editorRecipe = recipe
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .help("Edit \(recipe.name)")
                            Button {
                                store.duplicate(recipe)
                            } label: {
                                Image(systemName: "plus.square.on.square")
                            }
                            .buttonStyle(.plain)
                            .help("Duplicate \(recipe.name)")
                            Button(role: .destructive) {
                                store.delete(recipe.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Delete \(recipe.name)")
                        }
                        .padding(.vertical, 7)
                        if recipe.id != store.customRecipes.last?.id {
                            Divider()
                        }
                    }
                }
            }

            if !store.errorText.isEmpty {
                Label(store.errorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editorRecipe) { recipe in
            SmartMarkerRecipeEditor(
                recipe: recipe,
                onCancel: { editorRecipe = nil },
                onSave: {
                    store.save($0)
                    editorRecipe = nil
                }
            )
        }
    }

    private func builtInRecipeRow(_ recipe: SmartMarkerRecipe) -> some View {
        let isHidden = store.isHidden(recipe)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.title)
                Text(recipe.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            outputBadge(recipe.outputKind)
            Button {
                store.setHidden(!isHidden, for: recipe)
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isHidden ? "Show in AI Suggestions" : "Hide from AI Suggestions")
            .accessibilityLabel(
                isHidden
                    ? "Show \(recipe.title) in AI Suggestions"
                    : "Hide \(recipe.title) from AI Suggestions"
            )
        }
        .padding(.vertical, 6)
        .opacity(isHidden ? 0.55 : 1)
    }

    private func outputBadge(_ outputKind: SmartMarkerOutputKind) -> some View {
        Text(outputKind.title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

private struct SmartMarkerRecipeEditor: View {
    @State private var draft: SmartMarkerCustomRecipe
    let onCancel: () -> Void
    let onSave: (SmartMarkerCustomRecipe) -> Void

    init(
        recipe: SmartMarkerCustomRecipe,
        onCancel: @escaping () -> Void,
        onSave: @escaping (SmartMarkerCustomRecipe) -> Void
    ) {
        _draft = State(initialValue: recipe)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Custom Analysis")
                .font(.title2.weight(.semibold))

            Form {
                TextField(
                    "Name",
                    text: $draft.name,
                    prompt: Text("New Analysis")
                )
                TextField(
                    "Description",
                    text: $draft.summary,
                    prompt: Text("Describe what this analysis should find.")
                )

                Picker("Output", selection: $draft.outputKind) {
                    ForEach(SmartMarkerOutputKind.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                .pickerStyle(.segmented)

                if draft.outputKind == .text {
                    Picker(
                        "Text format",
                        selection: Binding(
                            get: { draft.textMode ?? .document },
                            set: { draft.textMode = $0 }
                        )
                    ) {
                        ForEach(SmartMarkerTextMode.allCases) {
                            Text($0.title).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(
                        (draft.textMode ?? .document) == .document
                            ? "Document creates unanchored long-form text such as a description or summary."
                            : "Timestamped List creates individually clickable lines tied to moments in the media."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Picker("Default scope", selection: $draft.defaultScope) {
                    ForEach(SmartMarkerScope.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                .pickerStyle(.segmented)

                if !(draft.outputKind == .text && (draft.textMode ?? .document) == .document) {
                    Picker("Default amount", selection: $draft.defaultDensity) {
                        ForEach(SmartMarkerDensity.allCases) {
                            Text($0.title).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Selection", selection: $draft.selectionStrategy) {
                        ForEach(SmartMarkerSelectionStrategy.allCases) {
                            Text($0.title).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)

                    Stepper(value: $draft.maximumResults, in: 1...60) {
                        Text("Maximum results: \(draft.maximumResults)")
                    }
                }

                if draft.outputKind == .markers {
                    Toggle("Prefer nearby audio pauses", isOn: $draft.prefersNearbyPauses)
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions")
                    .font(.headline)
                Text("Describe what the AI should find. In/Out supplies the transcript and enforces the selected output structure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $draft.instructions)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 130)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )
            }

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
}
