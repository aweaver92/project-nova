import SwiftUI
import NovaDomain

/// Knowledge tab: a natural-language search across the user's notes, bookmarks,
/// facts, and past conversations, plus the list of saved bookmarks.
public struct KnowledgeView: View {
    @Bindable var knowledge: KnowledgeViewModel

    public init(knowledge: KnowledgeViewModel) {
        self.knowledge = knowledge
    }

    public var body: some View {
        NavigationStack {
            List {
                if !knowledge.query.isEmpty {
                    resultsSection
                }
                bookmarksSection
            }
            .navigationTitle("Knowledge")
            .searchable(text: $knowledge.query, prompt: "Search your notes, bookmarks, chats")
            .onSubmit(of: .search) {
                Task { await knowledge.runSearch() }
            }
            .onChange(of: knowledge.query) { _, newValue in
                if newValue.isEmpty { knowledge.clearSearch() }
            }
            .task { await knowledge.load() }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        Section("Results") {
            if knowledge.isSearching {
                ProgressView()
            } else if knowledge.results.isEmpty {
                Text("No matches. Try different words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(knowledge.results) { hit in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: icon(for: hit.source))
                                .foregroundStyle(.secondary)
                            Text(hit.title).font(.subheadline).lineLimit(1)
                        }
                        Text(hit.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var bookmarksSection: some View {
        Section("Bookmarks") {
            if knowledge.bookmarks.isEmpty {
                Text("Say “Nova, bookmark this” after an answer to save it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(knowledge.bookmarks) { bookmark in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bookmark.title).font(.body).lineLimit(1)
                        Text(bookmark.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        Text(bookmark.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    Task { await knowledge.delete(at: offsets) }
                }
            }
        }
    }

    private func icon(for source: KnowledgeHit.Source) -> String {
        switch source {
        case .note: return "note.text"
        case .bookmark: return "bookmark"
        case .fact: return "person.text.rectangle"
        case .conversation: return "bubble.left.and.bubble.right"
        }
    }
}
