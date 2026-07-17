import SwiftUI
import NovaDomain

/// Library tab: your personal knowledge in one place. Notes and bookmarks are
/// listed for browsing/editing; the search field runs a unified search across
/// notes, bookmarks, facts, and past conversations. Merges the former Notes and
/// Knowledge tabs.
public struct LibraryView: View {
    @Bindable var notes: NotesViewModel
    @Bindable var knowledge: KnowledgeViewModel

    public init(notes: NotesViewModel, knowledge: KnowledgeViewModel) {
        self.notes = notes
        self.knowledge = knowledge
    }

    public var body: some View {
        NavigationStack {
            List {
                if knowledge.query.isEmpty {
                    notesSection
                    bookmarksSection
                } else {
                    resultsSection
                }
            }
            .navigationTitle("Library")
            .searchable(text: $knowledge.query, prompt: "Search notes, bookmarks, chats")
            .onSubmit(of: .search) {
                Task { await knowledge.runSearch() }
            }
            .onChange(of: knowledge.query) { _, newValue in
                if newValue.isEmpty { knowledge.clearSearch() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !notes.notes.isEmpty {
                        ShareLink(item: notes.exportText) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share notes")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        NoteEditorView(note: nil, notes: notes)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New note")
                }
            }
            .task {
                await notes.load()
                await knowledge.load()
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var notesSection: some View {
        Section("Notes") {
            if notes.notes.isEmpty {
                Text("Tap the compose button, or say “Nova, take a note …”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(notes.notes) { note in
                    NavigationLink {
                        NoteEditorView(note: note, notes: notes)
                    } label: {
                        noteRow(note)
                    }
                }
                .onDelete { offsets in
                    Task { await notes.delete(at: offsets) }
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

    // MARK: - Rows

    @ViewBuilder
    private func noteRow(_ note: Note) -> some View {
        let lines = note.text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        VStack(alignment: .leading, spacing: 3) {
            Text(lines.first ?? "New Note")
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                Text(lines.count > 1 ? lines[1] : "")
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
