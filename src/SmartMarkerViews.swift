import AppKit
import SwiftUI

private enum SmartMarkerSetupMode: String, CaseIterable, Identifiable {
    case freeform = "Freeform"
    case presetTasks = "Preset Tasks"

    var id: String { rawValue }
}

struct SmartMarkerSetupSheet: View {
    let canUseSelectedClip: Bool
    let onCancel: () -> Void
    let onStart: (SmartMarkerAnalysisConfiguration) -> Void

    @StateObject private var recipeStore = SmartMarkerRecipeStore.shared
    @State private var recipe: SmartMarkerAnalysisRecipe = .topicChanges
    @State private var providerID = SmartMarkerPreferences.providerID
    @State private var scope: SmartMarkerScope = .selectedClip
    @State private var density: SmartMarkerDensity = .standard
    @State private var preferNearbyPauses = true
    @State private var adHocPrompt = ""
    @State private var adHocScope: SmartMarkerScope = .entireVideo
    @State private var setupMode: SmartMarkerSetupMode = .freeform

    private var availabilityMessage: String? {
        SmartMarkerAnalyzer.availabilityMessage(for: providerID)
    }

    private var allowsNearbyPauses: Bool {
        recipe.isAdBreaks ||
            (recipe.builtInRecipe == nil && recipe.outputKind == .markers)
    }

    private var visibleBuiltInRecipes: [SmartMarkerRecipe] {
        SmartMarkerRecipe.allCases.filter { !recipeStore.isHidden($0) }
    }

    private var availableRecipes: [SmartMarkerAnalysisRecipe] {
        visibleBuiltInRecipes.map(SmartMarkerAnalysisRecipe.builtIn) +
            recipeStore.customRecipes.map(SmartMarkerAnalysisRecipe.custom)
    }

    private var isSelectedRecipeAvailable: Bool {
        availableRecipes.contains { $0.id == recipe.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI Suggestions")
                .font(.title2.weight(.semibold))

            Picker("Suggestion Mode", selection: $setupMode) {
                ForEach(SmartMarkerSetupMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)

            if setupMode == .freeform {
                freeformContent
            } else {
                presetTasksContent
            }

            Divider()
            providerFooter
            actionButtons
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            if !canUseSelectedClip {
                scope = .entireVideo
                adHocScope = .entireVideo
            }
            ensureRecipeSelection()
        }
        .onChange(of: recipeStore.hiddenBuiltInRecipes) { _, _ in
            ensureRecipeSelection()
        }
        .onChange(of: recipeStore.customRecipes) { _, _ in
            ensureRecipeSelection()
        }
    }

    private var freeformContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask a question or request text from this transcript")
                .font(.headline)

            TextField(
                "Summarize the strongest arguments in this video",
                text: $adHocPrompt,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(4...8)
            .onSubmit(startAdHocAnalysis)

            LabeledContent("Scope") {
                Picker("Freeform Scope", selection: $adHocScope) {
                    ForEach(SmartMarkerScope.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
        }
    }

    private var presetTasksContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a task")
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !visibleBuiltInRecipes.isEmpty {
                        Text("Built In")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(visibleBuiltInRecipes) {
                            recipeOption(.builtIn($0))
                        }
                    }
                    if !recipeStore.customRecipes.isEmpty {
                        Text("Custom")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(recipeStore.customRecipes) {
                            recipeOption(.custom($0))
                        }
                    }
                    if availableRecipes.isEmpty {
                        Label(
                            "No tasks are visible. Show a built-in task or add a custom task in Settings.",
                            systemImage: "eye.slash"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxHeight: 300)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Scope") {
                    Picker("Task Scope", selection: $scope) {
                        ForEach(SmartMarkerScope.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .disabled(recipe.isYouTubeChapters)
                }

                if !recipe.isDocumentText {
                    LabeledContent("Suggestions") {
                        Picker("Suggestions", selection: $density) {
                            ForEach(SmartMarkerDensity.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }
                }

                if allowsNearbyPauses {
                    Toggle("Prefer nearby audio pauses", isOn: $preferNearbyPauses)
                }
            }
        }
    }

    private var providerFooter: some View {
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(providerSummary)
                    if let availabilityMessage {
                        Text(availabilityMessage)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: availabilityMessage == nil ? providerIcon : "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(availabilityMessage == nil ? Color.secondary : Color(nsColor: .systemOrange))
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Menu("Change…") {
                ForEach(SmartMarkerProviderID.allCases) { provider in
                    Button {
                        providerID = provider
                    } label: {
                        if provider == providerID {
                            Label(provider.title, systemImage: "checkmark")
                        } else {
                            Text(provider.title)
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var actionButtons: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(primaryActionTitle, action: performPrimaryAction)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canPerformPrimaryAction)
        }
    }

    private var providerSummary: String {
        guard let model = SmartMarkerPreferences.model(for: providerID), !model.isEmpty else {
            return "Using \(providerID.title)"
        }
        return "Using \(providerID.title) · \(model)"
    }

    private var providerIcon: String {
        providerID == .appleIntelligence ? "lock.fill" : "network"
    }

    private var primaryActionTitle: String {
        if setupMode == .freeform {
            return "Ask AI"
        }
        if recipe.isYouTubeChapters {
            return "Create Chapters"
        }
        return recipe.isDocumentText ? "Generate Text" : "Generate Suggestions"
    }

    private var canPerformPrimaryAction: Bool {
        if setupMode == .freeform {
            return canStartAdHocAnalysis
        }
        return isSelectedRecipeAvailable &&
            availabilityMessage == nil &&
            (scope != .selectedClip || canUseSelectedClip)
    }

    private func performPrimaryAction() {
        if setupMode == .freeform {
            startAdHocAnalysis()
        } else {
            startPresetTask()
        }
    }

    private func startPresetTask() {
        guard canPerformPrimaryAction else { return }
        SmartMarkerPreferences.providerID = providerID
        onStart(
            SmartMarkerAnalysisConfiguration(
                providerID: providerID,
                modelIdentifier: SmartMarkerPreferences.model(for: providerID),
                recipe: recipe,
                scope: scope,
                density: density,
                preferNearbyPauses: preferNearbyPauses
            )
        )
    }

    private var normalizedAdHocPrompt: String {
        adHocPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canStartAdHocAnalysis: Bool {
        !normalizedAdHocPrompt.isEmpty &&
            availabilityMessage == nil &&
            (adHocScope != .selectedClip || canUseSelectedClip)
    }

    private func startAdHocAnalysis() {
        guard canStartAdHocAnalysis else { return }
        SmartMarkerPreferences.providerID = providerID
        onStart(
            SmartMarkerAnalysisConfiguration(
                providerID: providerID,
                modelIdentifier: SmartMarkerPreferences.model(for: providerID),
                recipe: .adHoc(normalizedAdHocPrompt),
                scope: adHocScope,
                density: .standard,
                preferNearbyPauses: false
            )
        )
    }

    private func recipeOption(_ option: SmartMarkerAnalysisRecipe) -> some View {
        Button {
            selectRecipe(option)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: recipe == option ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(recipe == option ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .foregroundStyle(.primary)
                    Text(option.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text(option.resultTypeTitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.10))
                    )
                    .padding(.top, 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func ensureRecipeSelection() {
        guard !isSelectedRecipeAvailable, let first = availableRecipes.first else { return }
        selectRecipe(first)
    }

    private func selectRecipe(_ option: SmartMarkerAnalysisRecipe) {
        recipe = option
        scope = option.defaultScope
        density = option.defaultDensity
        preferNearbyPauses = option.prefersNearbyPauses
        if !canUseSelectedClip, scope == .selectedClip {
            scope = .entireVideo
        }
    }
}

private struct SmartMarkerRefinementDisplayRevision: Equatable {
    let tabID: UUID?
    let revisionCount: Int
}

struct SmartMarkerReviewView: View {
    let tabs: [SmartMarkerAnalysisTab]
    let activeTabID: UUID?
    let onSelectTab: (UUID) -> Void
    let onCloseTab: (UUID) -> Void
    let onNewAnalysis: () -> Void
    let onHighlight: (SmartMarkerSuggestion) -> Void
    let onPlay: (SmartMarkerSuggestion) -> Void
    let onDeleteSuggestion: (UUID) -> Void
    let onSetScrollPosition: (UUID?, UUID) -> Void
    let onSelectResultVersion: (Int, UUID) -> Void
    let onCancelAnalysis: (UUID) -> Void
    let onRefine: (UUID, String) -> Void
    let onUndoRefinement: (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copiedSuggestionID: UUID?
    @State private var copiedAllTabID: UUID?
    @State private var refinementDraft = ""
    @State private var refinementUpdatePulse = false
    @State private var refinementUpdatePulseGeneration = 0

    private var activeTab: SmartMarkerAnalysisTab? {
        guard let activeTabID else { return nil }
        return tabs.first(where: { $0.id == activeTabID })
    }

    private var activeRefinementDisplayRevision: SmartMarkerRefinementDisplayRevision {
        SmartMarkerRefinementDisplayRevision(
            tabID: activeTab?.id,
            revisionCount: activeTab?.refinementRevisions.count ?? 0
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let activeTab {
                let displayedResult = activeTab.displayedResult
                resultsHeader(for: activeTab)

                if tabs.count > 1 {
                    tabStrip
                }

                if activeTab.isAnalyzing {
                    HStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                        Text(activeTab.progressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") {
                            onCancelAnalysis(activeTab.id)
                        }
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                if !activeTab.warningText.isEmpty {
                    Label(activeTab.warningText, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if activeTab.supportsResultHistory,
                   activeTab.latestResultVersionIndex > 0 {
                    resultHistoryControl(for: activeTab)
                }

                if !activeTab.errorText.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn’t Generate Suggestions", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(activeTab.errorText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if activeTab.configuration.recipe.isDocumentText,
                          !displayedResult.documentText.isEmpty {
                    documentResult(displayedResult.documentText, for: activeTab)
                } else if displayedResult.suggestions.isEmpty {
                    if !activeTab.isAnalyzing {
                        ContentUnavailableView(
                            "No Suggestions",
                            systemImage: "mappin.slash",
                            description: Text("This analysis did not find any useful points.")
                        )
                    }
                    Spacer(minLength: 0)
                } else {
                    ScrollViewReader { proxy in
                        List(displayedResult.suggestions) { suggestion in
                            SmartMarkerSuggestionRow(
                                suggestion: suggestion,
                                recipe: activeTab.configuration.recipe,
                                isHighlighted: activeTab.highlightedSuggestionID == suggestion.id,
                                didCopy: copiedSuggestionID == suggestion.id,
                                onCopy: {
                                    copySuggestion(
                                        suggestion,
                                        outputKind: activeTab.configuration.recipe.outputKind
                                    )
                                },
                                onDelete: {
                                    onDeleteSuggestion(suggestion.id)
                                },
                                allowsDeletion: activeTab.isViewingCurrentResult,
                                onActivate: {
                                    onHighlight(suggestion)
                                },
                                onPlay: {
                                    onPlay(suggestion)
                                }
                            )
                            .id(suggestion.id)
                        }
                        .listStyle(.inset)
                        .scrollPosition(
                            id: Binding(
                                get: { activeTab.scrollPositionSuggestionID },
                                set: { onSetScrollPosition($0, activeTab.id) }
                            )
                        )
                        .onChange(of: activeTab.highlightedSuggestionID) { _, id in
                            guard let id else { return }
                            proxy.scrollTo(id, anchor: .center)
                        }
                        .onAppear {
                            let target = activeTab.scrollPositionSuggestionID ??
                                activeTab.highlightedSuggestionID
                            guard let target else { return }
                            DispatchQueue.main.async {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                    .id("\(activeTab.id.uuidString)-\(activeTab.resolvedResultVersionIndex)")

                    HStack {
                        Spacer()
                        Button {
                            copyAll(
                                displayedResult.suggestions,
                                outputKind: activeTab.configuration.recipe.outputKind
                            )
                        } label: {
                            let didCopyAll = copiedAllTabID == activeTab.id
                            Label(
                                didCopyAll ? "Copied" : "Copy All",
                                systemImage: didCopyAll ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if !activeTab.isAnalyzing,
                   (!displayedResult.suggestions.isEmpty || !displayedResult.documentText.isEmpty) {
                    refinementPanel(for: activeTab)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(refinementUpdatePulse ? 0.05 : 0))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            Color.accentColor.opacity(refinementUpdatePulse ? 0.28 : 0),
                            lineWidth: 1
                        )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onChange(of: activeTabID) { _, _ in
            refinementDraft = ""
        }
        .onChange(of: activeRefinementDisplayRevision) { previous, current in
            guard previous.tabID == current.tabID,
                  current.tabID != nil,
                  current.revisionCount > previous.revisionCount else {
                return
            }
            showRefinementUpdatePulse()
        }
    }

    private func showRefinementUpdatePulse() {
        refinementUpdatePulseGeneration &+= 1
        let generation = refinementUpdatePulseGeneration

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            refinementUpdatePulse = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 40 : 70))
            guard !Task.isCancelled,
                  generation == refinementUpdatePulseGeneration else {
                return
            }
            withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.42)) {
                refinementUpdatePulse = false
            }
        }
    }

    private func resultsHeader(for tab: SmartMarkerAnalysisTab) -> some View {
        let resultCount = countText(
            tab.displayedResult.suggestions.count,
            recipe: tab.configuration.recipe
        )
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tab.title)
                        .font(.headline)
                    if tabs.count == 1 {
                        Button {
                            onCloseTab(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 13, height: 13)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Close \(tab.title)")
                        .accessibilityLabel("Close \(tab.title)")
                    }
                }
                Text("\(resultCount) · \(tab.configuration.providerID.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
                if tab.configuration.recipe.isAdHoc {
                    Text(tab.configuration.recipe.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(tab.configuration.recipe.description)
                }
            }

            Spacer(minLength: 12)

            Button(action: onNewAnalysis) {
                Label("New Analysis…", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(tabs.contains { $0.isAnalyzing || $0.isRefining })
        }
        .padding(.horizontal, 4)
    }

    private func resultHistoryControl(for tab: SmartMarkerAnalysisTab) -> some View {
        let versionIndex = tab.resolvedResultVersionIndex
        let versionCount = tab.latestResultVersionIndex + 1
        let instruction = tab.displayedResult.refinementInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Button {
                    onSelectResultVersion(versionIndex - 1, tab.id)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(versionIndex == 0)
                .help("Show Previous Version")
                .accessibilityLabel("Show Previous Version")

                Text("Version \(versionIndex + 1) of \(versionCount)")
                    .font(.caption.monospacedDigit())

                Button {
                    onSelectResultVersion(versionIndex + 1, tab.id)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(versionIndex == tab.latestResultVersionIndex)
                .help("Show Next Version")
                .accessibilityLabel("Show Next Version")

                Text(tab.isViewingCurrentResult ? "Current" : "Earlier Version")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }

            if let instruction, !instruction.isEmpty {
                Text("Refinement: \(instruction)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(instruction)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    private func refinementPanel(for tab: SmartMarkerAnalysisTab) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            if !tab.refinementMessages.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(tab.refinementMessages) { message in
                            HStack {
                                if message.role == .user {
                                    Spacer(minLength: 28)
                                }
                                Text(message.text)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(
                                        message.role == .user
                                            ? Color.accentColor.opacity(0.14)
                                            : Color.secondary.opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                if message.role == .assistant {
                                    Spacer(minLength: 28)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 130)
            }

            if !tab.refinementErrorText.isEmpty {
                Label(tab.refinementErrorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    "Ask AI about these results or request changes…",
                    text: $refinementDraft,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit {
                    submitRefinement(for: tab)
                }

                Button {
                    submitRefinement(for: tab)
                } label: {
                    Image(systemName: "arrow.up")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    tab.isRefining ||
                        refinementDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .help("Send to AI")
            }

            HStack {
                if tab.isRefining {
                    ProgressView()
                        .controlSize(.small)
                    Text("Thinking…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !tab.supportsResultHistory, !tab.refinementRevisions.isEmpty {
                    Button("Undo Refinement") {
                        onUndoRefinement(tab.id)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .disabled(tab.isRefining)
                }
            }

            if tab.supportsResultHistory, !tab.isViewingCurrentResult {
                Text("Refining this version will create a new current version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func submitRefinement(for tab: SmartMarkerAnalysisTab) {
        let message = refinementDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !tab.isRefining else { return }
        refinementDraft = ""
        onRefine(tab.id, message)
    }

    private func documentResult(_ text: String, for tab: SmartMarkerAnalysisTab) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
            )

            HStack {
                Spacer()
                Button {
                    copyToPasteboard(text)
                    copiedAllTabID = tab.id
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        guard !Task.isCancelled, copiedAllTabID == tab.id else { return }
                        copiedAllTabID = nil
                    }
                } label: {
                    let didCopy = copiedAllTabID == tab.id
                    Label(
                        didCopy ? "Copied" : "Copy Text",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    HStack(spacing: 5) {
                        if tab.isAnalyzing || tab.isRefining {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Button(tab.title) {
                            onSelectTab(tab.id)
                        }
                        .buttonStyle(.plain)
                        .lineLimit(1)

                        Button {
                            onCloseTab(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 13, height: 13)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Close \(tab.title)")
                        .accessibilityLabel("Close \(tab.title)")
                    }
                    .padding(.leading, 9)
                    .padding(.trailing, 6)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                tab.id == activeTabID
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.secondary.opacity(0.08)
                            )
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func copySuggestion(
        _ suggestion: SmartMarkerSuggestion,
        outputKind: SmartMarkerOutputKind
    ) {
        copyToPasteboard(copyText(for: suggestion, outputKind: outputKind))
        copiedSuggestionID = suggestion.id
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, copiedSuggestionID == suggestion.id else { return }
            copiedSuggestionID = nil
        }
    }

    private func copyAll(
        _ suggestions: [SmartMarkerSuggestion],
        outputKind: SmartMarkerOutputKind
    ) {
        guard let activeTabID else { return }
        let text: String
        if outputKind == .text {
            text = suggestions.map {
                copyText(for: $0, outputKind: outputKind)
            }.joined(separator: "\n")
        } else {
            text = suggestions.map {
                "\(timecodeText(for: $0)) — \($0.label)\n\($0.explanation)"
            }.joined(separator: "\n\n")
        }
        copyToPasteboard(text)
        copiedAllTabID = activeTabID
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, copiedAllTabID == activeTabID else { return }
            copiedAllTabID = nil
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func timecodeText(for suggestion: SmartMarkerSuggestion) -> String {
        guard let endSeconds = suggestion.endSeconds else {
            return formatSeconds(suggestion.seconds)
        }
        return "\(formatSeconds(suggestion.seconds)) → \(formatSeconds(endSeconds))"
    }

    private func copyText(
        for suggestion: SmartMarkerSuggestion,
        outputKind: SmartMarkerOutputKind
    ) -> String {
        if outputKind == .text {
            return smartMarkerTextLine(for: suggestion)
        }
        return timecodeText(for: suggestion)
    }

    private func countText(_ count: Int, recipe: SmartMarkerAnalysisRecipe) -> String {
        if recipe.isDocumentText {
            return "Document"
        }
        if recipe.isYouTubeChapters {
            return "\(count) \(count == 1 ? "Chapter" : "Chapters")"
        }
        if recipe.outputKind == .text {
            return "\(count) \(count == 1 ? "Text Item" : "Text Items")"
        }
        return "\(count) \(count == 1 ? "Suggestion" : "Suggestions")"
    }
}

private struct SmartMarkerSuggestionRow: View {
    let suggestion: SmartMarkerSuggestion
    let recipe: SmartMarkerAnalysisRecipe
    let isHighlighted: Bool
    let didCopy: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    let allowsDeletion: Bool
    let onActivate: () -> Void
    let onPlay: () -> Void

    private var outputKind: SmartMarkerOutputKind {
        recipe.outputKind
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button(action: onActivate) {
                VStack(alignment: .leading, spacing: 3) {
                    if outputKind == .text {
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Text(formatSmartMarkerChapterTimestamp(suggestion.seconds))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(suggestion.label)
                                .font(.body.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if let endSeconds = suggestion.endSeconds {
                        HStack(spacing: 5) {
                            Text(formatSeconds(suggestion.seconds))
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                            Text(formatSeconds(endSeconds))
                            Text(compactDuration(endSeconds - suggestion.seconds))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.10))
                                )
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        Text(suggestion.label)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                    } else {
                        HStack(spacing: 7) {
                            Text(formatSeconds(suggestion.seconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(suggestion.label)
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                        }
                    }
                    if outputKind != .text {
                        Text(suggestion.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded(onPlay)
            )

            HStack(spacing: 8) {
                Button(action: onCopy) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(didCopy ? Color.accentColor : Color.secondary)
                .help(copyButtonLabel)
                .accessibilityLabel(copyButtonLabel)

                if allowsDeletion {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Delete Suggestion")
                    .accessibilityLabel("Delete Suggestion")
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 3)
        .background(
            isHighlighted ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private func compactDuration(_ duration: Double) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return minutes > 0
            ? String(format: "%d:%02d", minutes, seconds)
            : "\(seconds)s"
    }

    private var copyButtonLabel: String {
        switch outputKind {
        case .text: return recipe.isYouTubeChapters ? "Copy Chapter" : "Copy Text"
        case .ranges: return "Copy Range"
        case .markers: return "Copy Timecode"
        }
    }
}
