import SwiftUI

private struct HelpDocumentationContent: Decodable {
    let schemaVersion: Int
    let topics: [HelpTopic]
}

private struct HelpSection: Identifiable, Decodable {
    let id: String
    let title: String
    let paragraphs: [String]
    let bullets: [String]
    let steps: [String]
    let note: String?
}

private struct HelpShortcut: Identifiable, Decodable {
    let id: String
    let action: String
    let keys: [String]
}

private struct HelpShortcutGroup: Identifiable, Decodable {
    let id: String
    let title: String
    let items: [HelpShortcut]
}

private struct HelpTopic: Identifiable, Decodable {
    let id: String
    let title: String
    let summary: String
    let symbolName: String
    let order: Int
    let sections: [HelpSection]
    let shortcutGroups: [HelpShortcutGroup]
}

private enum HelpDocumentationLoader {
    static func load() throws -> [HelpTopic] {
        guard let url = Bundle.main.url(forResource: "help-content", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let content = try JSONDecoder().decode(HelpDocumentationContent.self, from: Data(contentsOf: url))
        guard content.schemaVersion == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return content.topics.sorted { $0.order < $1.order }
    }
}

private func helpAttributedString(_ content: String) -> AttributedString {
    (try? AttributedString(markdown: content)) ?? AttributedString(content)
}

struct HelpDocumentationView: View {
    @State private var selection: HelpTopic.ID?
    private let topics: [HelpTopic]
    private let loadError: String?

    init() {
        do {
            let loadedTopics = try HelpDocumentationLoader.load()
            topics = loadedTopics
            loadError = nil
            _selection = State(initialValue: loadedTopics.first?.id)
        } catch {
            topics = []
            loadError = error.localizedDescription
            _selection = State(initialValue: nil)
        }
    }

    private var selectedTopic: HelpTopic? {
        topics.first(where: { $0.id == selection }) ?? topics.first
    }

    var body: some View {
        NavigationSplitView {
            List(topics, selection: $selection) { topic in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.title)
                            .font(.body.weight(.medium))
                        Text(topic.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } icon: {
                    Image(systemName: topic.symbolName)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .tag(topic.id)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 260)
        } detail: {
            if let selectedTopic {
                helpArticle(selectedTopic)
            } else {
                ContentUnavailableView(
                    "Help Isn’t Available",
                    systemImage: "questionmark.circle",
                    description: Text(loadError ?? "The Help content could not be loaded.")
                )
            }
        }
        .frame(minWidth: 820, minHeight: 620)
    }

    private func helpArticle(_ topic: HelpTopic) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(topic.title, systemImage: topic.symbolName)
                        .font(.largeTitle.weight(.semibold))
                    Text(topic.summary)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(topic.sections) { section in
                    HelpArticleSectionView(section: section)
                }

                if !topic.shortcutGroups.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(topic.shortcutGroups) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group.title)
                                    .font(.headline)

                                VStack(spacing: 8) {
                                    ForEach(group.items) { item in
                                        shortcutRow(item)
                                    }
                                }
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(helpCardBackground)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var helpCardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private func shortcutRow(_ item: HelpShortcut) -> some View {
        HStack(spacing: 16) {
            Text(item.action)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(item.keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                }
            }
            .fixedSize()
        }
    }
}

private struct HelpArticleSectionView: View {
    let section: HelpSection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.title)
                .font(.title3.weight(.semibold))

            ForEach(section.paragraphs, id: \.self) { paragraph in
                Text(helpAttributedString(paragraph))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !section.steps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1).")
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .trailing)
                            Text(helpAttributedString(step))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !section.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(section.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(.secondary)
                                .padding(.top, 7)
                            Text(helpAttributedString(bullet))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let note = section.note {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.secondary)
                    Text(helpAttributedString(note))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }
}
