import SwiftUI
import NovaDomain
#if canImport(UIKit)
import UIKit
#endif

/// Library tab: your personal knowledge in one place. Notes and bookmarks are
/// listed for browsing/editing; the search field runs a unified search across
/// notes, bookmarks, facts, and past conversations. Merges the former Notes and
/// Knowledge tabs.
public struct LibraryView: View {
    @Bindable var notes: NotesViewModel
    @Bindable var knowledge: KnowledgeViewModel
    @Bindable var visual: VisualMemoryViewModel

    public init(notes: NotesViewModel, knowledge: KnowledgeViewModel, visual: VisualMemoryViewModel) {
        self.notes = notes
        self.knowledge = knowledge
        self.visual = visual
    }

    public var body: some View {
        NavigationStack {
            List {
                if knowledge.query.isEmpty {
                    notesSection
                    visualMemorySection
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
                await visual.load()
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
    private var visualMemorySection: some View {
        Section {
            if visual.items.isEmpty {
                Text("Say “Nova, remember this” to save what you’re looking at. Sightings show up here and in search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(visual.items) { item in
                        NavigationLink {
                            VisualMemoryDetail(item: item, url: visual.imageURL(for: item), visual: visual)
                        } label: {
                            VisualThumbnail(url: visual.imageURL(for: item), caption: item.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
        } header: {
            HStack {
                Text("Sightings")
                Spacer()
                if !visual.items.isEmpty {
                    Button(role: .destructive) {
                        Task { await visual.clear() }
                    } label: {
                        Text("Clear").font(.caption)
                    }
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
        case .visualMemory: return "eye"
        }
    }
}

/// Loads a saved sighting image from disk (no caching layer needed — glasses
/// stills are small and few).
private func loadImage(_ url: URL?) -> Image? {
    guard let url else { return nil }
    #if canImport(UIKit)
    guard let ui = UIImage(contentsOfFile: url.path) else { return nil }
    return Image(uiImage: ui)
    #else
    return nil
    #endif
}

private struct VisualThumbnail: View {
    let url: URL?
    let caption: String

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let image = loadImage(url) {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if !caption.isEmpty {
                Text(caption)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct VisualMemoryDetail: View {
    let item: VisualMemoryItem
    let url: URL?
    @Bindable var visual: VisualMemoryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let image = loadImage(url) {
                    image
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !item.text.isEmpty {
                    Text("Text read from this")
                        .font(.headline)
                    Text(item.text)
                        .font(.callout)
                        .textSelection(.enabled)
                } else {
                    Text("No text was found in this image.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle(item.caption.isEmpty ? "Sighting" : item.caption)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let url {
                        ShareLink(item: url) { Label("Share image", systemImage: "square.and.arrow.up") }
                    }
                    Button(role: .destructive) {
                        Task { await visual.delete(item); dismiss() }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}
