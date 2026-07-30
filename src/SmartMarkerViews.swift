import AppKit
import SwiftUI

struct SmartMarkerSetupSheet: View {
    let canUseSelectedClip: Bool
    let onCancel: () -> Void
    let onStart: (SmartMarkerAnalysisConfiguration) -> Void

    @State private var recipe: SmartMarkerRecipe = .topicChanges
    @State private var providerID = SmartMarkerPreferences.providerID
    @State private var scope: SmartMarkerScope = .selectedClip
    @State private var density: SmartMarkerDensity = .standard
    @State private var preferNearbyPauses = true

    private var availabilityMessage: String? {
        SmartMarkerAnalyzer.availabilityMessage(for: providerID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("AI Suggestions")
                    .font(.title2.weight(.semibold))
                Text("Use \(providerID.title) to find useful points in the transcript.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("What should In/Out find?")
                    .font(.headline)
                ForEach(SmartMarkerRecipe.allCases) { option in
                    Button {
                        recipe = option
                        if option == .youtubeChapters {
                            scope = .entireVideo
                        }
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
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("AI provider") {
                    Picker("AI Provider", selection: $providerID) {
                        ForEach(SmartMarkerProviderID.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 240)
                }

                LabeledContent("Scope") {
                    Picker("Scope", selection: $scope) {
                        ForEach(SmartMarkerScope.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .disabled(recipe == .youtubeChapters)
                }

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

                if recipe == .adBreaks {
                    Toggle("Prefer nearby audio pauses", isOn: $preferNearbyPauses)
                }
            }

            if let availabilityMessage {
                Label(availabilityMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(
                    providerID == .appleIntelligence
                        ? "Analysis runs privately on this Mac."
                        : "Transcript text will be sent to OpenAI.",
                    systemImage: providerID == .appleIntelligence ? "lock.fill" : "network"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(recipe == .youtubeChapters ? "Create Chapters" : "Generate Suggestions") {
                    SmartMarkerPreferences.providerID = providerID
                    onStart(
                        SmartMarkerAnalysisConfiguration(
                            providerID: providerID,
                            modelIdentifier: providerID == .openAI
                                ? SmartMarkerPreferences.openAIModel
                                : nil,
                            recipe: recipe,
                            scope: scope,
                            density: density,
                            preferNearbyPauses: preferNearbyPauses
                        )
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(availabilityMessage != nil || (scope == .selectedClip && !canUseSelectedClip))
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            if !canUseSelectedClip {
                scope = .entireVideo
            }
        }
    }
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
    let onCancelAnalysis: (UUID) -> Void

    @State private var copiedSuggestionID: UUID?
    @State private var copiedAllTabID: UUID?

    private var activeTab: SmartMarkerAnalysisTab? {
        guard let activeTabID else { return nil }
        return tabs.first(where: { $0.id == activeTabID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let activeTab {
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

                if !activeTab.errorText.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn’t Generate Suggestions", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(activeTab.errorText)
                    }
                } else if activeTab.suggestions.isEmpty {
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
                        List(activeTab.suggestions) { suggestion in
                            SmartMarkerSuggestionRow(
                                suggestion: suggestion,
                                outputKind: activeTab.configuration.recipe.outputKind,
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
                    .id(activeTab.id)

                    HStack {
                        Spacer()
                        Button {
                            copyAll(
                                activeTab.suggestions,
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
            }
        }
    }

    private func resultsHeader(for tab: SmartMarkerAnalysisTab) -> some View {
        let resultCount = countText(
            tab.suggestions.count,
            outputKind: tab.configuration.recipe.outputKind
        )
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tab.configuration.recipe.title)
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
            }

            Spacer(minLength: 12)

            Button(action: onNewAnalysis) {
                Label("New Analysis…", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(tabs.contains(where: \.isAnalyzing))
        }
        .padding(.horizontal, 4)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    HStack(spacing: 5) {
                        if tab.isAnalyzing {
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

    private func countText(_ count: Int, outputKind: SmartMarkerOutputKind) -> String {
        if outputKind == .text {
            return "\(count) \(count == 1 ? "Chapter" : "Chapters")"
        }
        return "\(count) \(count == 1 ? "Suggestion" : "Suggestions")"
    }
}

private struct SmartMarkerSuggestionRow: View {
    let suggestion: SmartMarkerSuggestion
    let outputKind: SmartMarkerOutputKind
    let isHighlighted: Bool
    let didCopy: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onActivate: () -> Void
    let onPlay: () -> Void

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

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete Suggestion")
                .accessibilityLabel("Delete Suggestion")
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
        case .text: return "Copy Chapter"
        case .ranges: return "Copy Range"
        case .markers: return "Copy Timecode"
        }
    }
}
