import SwiftUI
import AppKit
import InOutCore

struct TranscriptCleanupToolbarControls: View {
    let model: WorkspaceViewModel
    @ObservedObject var session: TranscriptCleanupSession
    let isOptionKeyPressed: Bool
    @State private var showsPopover = false

    private var quickMode: Bool { isOptionKeyPressed && session.canStartNewCleanup }
    private var title: String {
        if quickMode { return "Quick Clean Up" }
        if session.phase == .ready && !session.edits.isEmpty { return "Review \(session.edits.count) Corrections" }
        return "Clean Up"
    }

    var body: some View {
        Button {
            if session.canStartNewCleanup && (isOptionKeyPressed || NSEvent.modifierFlags.contains(.option)) {
                showsPopover = false
                model.startDefaultTranscriptCleanup(automaticallyApply: true)
                if session.phase == .failed { showsPopover = true }
            } else {
                showsPopover.toggle()
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                Label(title, systemImage: "sparkles").fixedSize()
                if session.phase == .ready && !session.edits.isEmpty {
                    Label("Review \(session.edits.count)", systemImage: "sparkles").fixedSize()
                }
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(model.isGeneratingTranscript || !transcriptHasWordTimings(model.transcriptSegments))
        .help(quickMode ? "Clean up and apply all corrections automatically." : "Open transcript cleanup options and results. Option-click for Quick Clean Up.")
        .accessibilityLabel(title)
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            TranscriptCleanupPopover(model: model, session: session, source: model.sourcePresentation)
        }
    }
}

struct TranscriptCleanupPopover: View {
    let model: WorkspaceViewModel
    @ObservedObject var session: TranscriptCleanupSession
    @ObservedObject var source: SourcePresentationModel
    @Environment(\.dismiss) private var dismiss
    @State private var providerID: SmartMarkerProviderID
    @State private var glossary: String
    @State private var showsSetup = false
    @State private var errorText: String?

    init(model: WorkspaceViewModel, session: TranscriptCleanupSession, source: SourcePresentationModel) {
        self.model = model
        self.session = session
        self.source = source
        _providerID = State(initialValue: model.transcriptCleanupProviderID)
        _glossary = State(initialValue: model.transcriptCleanupGlossary)
    }

    private func perform(_ action: () throws -> Void) {
        do { errorText = nil; try action(); showsSetup = false }
        catch { errorText = error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsSetup && session.phase != .running {
                setup
            } else {
                switch session.phase {
                case .idle, .failed:
                    setup
                case .running:
                    Text("Cleaning Up Transcript").font(.headline)
                    Text(session.progress).foregroundStyle(.secondary)
                    if let fraction = session.progressFraction {
                        ProgressView(value: fraction).progressViewStyle(.linear)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text("Cleanup continues when you close this popover.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Spacer()
                        Button("Cancel Cleanup") { session.reset() }
                    }
                case .ready:
                    Text("Transcript Corrections").font(.headline)
                    if session.edits.isEmpty {
                        Text(session.skippedSuggestions == 0 ? "No corrections suggested." : "No corrections could be safely matched.")
                            .foregroundStyle(.secondary)
                        Divider()
                        HStack {
                            Spacer()
                            Button("Run Again…") { showsSetup = true }
                        }
                    } else {
                        Text("\(session.edits.count) correction\(session.edits.count == 1 ? "" : "s") ready. Your transcript hasn’t changed yet.")
                            .foregroundStyle(.secondary)
                        if session.skippedSuggestions > 0 {
                            Text("\(session.skippedSuggestions) suggestions could not be verified and were skipped.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        HStack {
                            Button("Review Corrections") { model.reviewTranscriptCleanup() }
                            Spacer(minLength: 8)
                            Button("Apply All") { perform { try model.applyTranscriptCleanup(acceptAll: true) } }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Discard Results") { session.reset() }
                            .buttonStyle(.borderless).font(.caption)
                    }
                case .applied:
                    Text("Transcript Cleaned Up").font(.headline)
                    Text("\(session.appliedCount) correction\(session.appliedCount == 1 ? "" : "s") applied. Caption timing is preserved.")
                        .foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Button("Undo Cleanup") { perform { try model.undoTranscriptCleanup() } }
                        Spacer()
                        Button("Run Again…") { showsSetup = true }
                    }
                }
            }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if model.originalTranscriptSegments != nil && session.phase != .running {
                Divider()
                Button("Restore Original Transcript") {
                    guard let original = model.originalTranscriptSegments else { return }
                    model.transcriptSegments = original
                    model.originalTranscriptSegments = nil
                    model.transcriptStatusText = "Original transcript restored."
                    model.saveTranscriptToLibrary(original)
                    errorText = nil
                    showsSetup = false
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption)
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(16).frame(width: 340)
        .onChange(of: source.sourceSessionID) { _, _ in dismiss() }
    }

    private var modelName: String {
        switch providerID {
        case .openAI: return SmartMarkerPreferences.openAIModel
        case .claude: return SmartMarkerPreferences.claudeModel
        case .gemini: return SmartMarkerPreferences.geminiModel
        case .appleIntelligence: return "On-device model"
        }
    }

    private var setup: some View {
        let availability = SmartMarkerProviderFactory.availabilityMessage(for: providerID)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Clean Up Transcript").font(.headline)
            HStack(spacing: 12) {
                Text("Provider").foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Picker("Provider", selection: $providerID) {
                    ForEach(SmartMarkerProviderID.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize()
            }
            HStack(spacing: 12) {
                Text("Model").foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(modelName).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            TextField("Names and context (optional)", text: $glossary, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            Text("Correct names and recognition errors without changing caption timing. Models are configured in Settings › AI.")
                .font(.caption).foregroundStyle(.secondary)
            if let availability { Text(availability).font(.caption).foregroundStyle(.secondary) }
            if session.phase == .failed, errorText == nil, let message = session.errorText {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Text(providerID == .appleIntelligence ? "Runs locally on your Mac." : "Transcript text and context are sent using your API key.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Quick Clean Up") {
                    perform {
                        try model.startTranscriptCleanup(providerID: providerID, glossary: glossary,
                                                         automaticallyApply: true)
                    }
                }
                .buttonStyle(.bordered)
                .help("Use the provider and context above and apply all corrections automatically. Undo remains available.")
                Spacer()
                Button(session.phase == .failed ? "Try Again" : "Start Cleanup") {
                    perform { try model.startTranscriptCleanup(providerID: providerID, glossary: glossary) }
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(source.isGeneratingTranscript || !transcriptHasWordTimings(source.transcriptSegments) || availability != nil)
            Text("Quick Clean Up applies all corrections without review.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TranscriptCleanupStatusView<DefaultStatus: View>: View {
    let model: WorkspaceViewModel
    @ObservedObject var session: TranscriptCleanupSession
    @ViewBuilder let defaultStatus: () -> DefaultStatus

    var body: some View {
        HStack(spacing: 8) {
            switch session.phase {
            case .applied:
                Label("\(session.appliedCount) correction\(session.appliedCount == 1 ? "" : "s") applied", systemImage: "checkmark.circle")
                Spacer(minLength: 0)
                Button("Undo") {
                    do { try model.undoTranscriptCleanup() }
                    catch { session.reportFailure(error) }
                }
            case .running:
                Text("Cleaning up transcript…")
            case .ready:
                if session.edits.isEmpty {
                    Text(session.skippedSuggestions == 0 ? "No corrections suggested." : "No corrections could be safely matched.")
                    Spacer(minLength: 0)
                    Button("Done") { session.reset() }
                } else {
                    Text("\(session.edits.count) correction\(session.edits.count == 1 ? "" : "s") ready for review.")
                }
            case .failed:
                Text(session.errorText ?? "Transcript cleanup failed.")
                    .foregroundStyle(.red).textSelection(.enabled).lineLimit(2)
            case .idle:
                defaultStatus()
            }
        }
        .font(.caption).foregroundStyle(.secondary).controlSize(.small)
    }
}

struct TranscriptCleanupSidebar<Transcript: View>: View {
    let model: WorkspaceViewModel
    @ObservedObject var session: TranscriptCleanupSession
    let play: (Double) -> Void
    @ViewBuilder let transcript: () -> Transcript
    @State private var errorText: String?

    private func perform(_ action: () throws -> Void) {
        do { errorText = nil; try action() }
        catch { errorText = error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.phase == .ready && !session.edits.isEmpty {
                Picker("Transcript view", selection: $session.isReviewing) {
                    Text("Transcript").tag(false)
                    Text("Corrections · \(session.edits.count)").tag(true)
                }
                .pickerStyle(.segmented).controlSize(.small).labelsHidden()
            }
            if session.phase == .ready && !session.edits.isEmpty && session.isReviewing {
                review
            } else {
                // Keep this view at the same structural position as cleanup runs and finishes,
                // preserving the native table's scroll position and selection.
                transcript()
            }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: session.phase) { _, _ in errorText = nil }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(session.selected.count) of \(session.edits.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(session.selected.count == session.edits.count ? "Deselect All" : "Select All") {
                    session.selected = session.selected.count == session.edits.count ? [] : Set(session.edits.map(\.id))
                }.buttonStyle(.borderless).font(.caption)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.edits) { edit in
                        TranscriptCleanupCorrectionRow(edit: edit, words: session.words,
                            included: Binding(get: { session.selected.contains(edit.id) }, set: { value in
                                if value { session.selected.insert(edit.id) } else { session.selected.remove(edit.id) }
                            }), play: play)
                    }
                }.padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.skippedSuggestions > 0 {
                Text("\(session.skippedSuggestions) suggestions skipped because they could not be safely verified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Caption timing stays the same.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Review Later") { session.isReviewing = false }
                Spacer(minLength: 0)
                Button("Apply \(session.selected.count) \(session.selected.count == 1 ? "Correction" : "Corrections")") { perform { try model.applyTranscriptCleanup() } }
                    .buttonStyle(.borderedProminent).disabled(session.selected.isEmpty)
            }.controlSize(.small)
            if session.selected.count != session.edits.count {
                Button("Apply All \(session.edits.count) \(session.edits.count == 1 ? "Correction" : "Corrections")") { perform { try model.applyTranscriptCleanup(acceptAll: true) } }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }
}

private struct TranscriptCleanupCorrectionRow: View {
    let edit: TranscriptCleanupEdit
    let words: [TranscriptCleanupWord]
    @Binding var included: Bool
    let play: (Double) -> Void

    private var prefix: String {
        let lower = max(0, edit.startWord - 7)
        return (lower > 0 ? "… " : "") + TranscriptCleanup.joinedText(words[lower..<edit.startWord].map(\.timing.word)) + (lower < edit.startWord ? " " : "")
    }
    private var suffix: String {
        let upper = min(words.count, edit.endWord + 8)
        return (edit.endWord + 1 < upper ? " " : "") + TranscriptCleanup.joinedText(words[(edit.endWord + 1)..<upper].map(\.timing.word)) + (upper < words.count ? " …" : "")
    }
    private var time: Double { words.indices.contains(edit.startWord) ? words[edit.startWord].timing.start : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Include correction", isOn: $included).labelsHidden().toggleStyle(.checkbox)
                    .accessibilityLabel("Include \(edit.original) to \(edit.replacement)")
                Text(formatSeconds(time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button { play(max(0, time - 2)) } label: { Label("Play Passage", systemImage: "play.fill") }
                    .buttonStyle(.borderless).font(.caption)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Original").font(.caption).foregroundStyle(.secondary)
                (Text(prefix) + Text(edit.original).strikethrough().foregroundColor(.secondary) + Text(suffix))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Corrected").font(.caption).foregroundStyle(.secondary)
                (Text(prefix) + Text(edit.replacement).bold() + Text(suffix))
            }
        }
        .font(.callout).textSelection(.enabled)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(included ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.2)))
    }
}
