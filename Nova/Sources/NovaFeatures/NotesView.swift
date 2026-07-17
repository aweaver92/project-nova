import SwiftUI
import NovaDomain

/// iOS Notes-style tab: a list of notes with create, edit, swipe-to-delete, and
/// export. The same store is shared with Nova's `save_note` / `list_notes` tools,
/// so notes captured by voice and notes edited by hand stay in sync.
public struct NotesView: View {
    @Bindable var notes: NotesViewModel

    public init(notes: NotesViewModel) {
        self.notes = notes
    }

    public var body: some View {
        NavigationStack {
            Group {
                if notes.notes.isEmpty {
                    ContentUnavailableView {
                        Label("No Notes", systemImage: "note.text")
                    } description: {
                        Text("Tap the compose button, or say “Nova, take a note …”.")
                    }
                } else {
                    List {
                        ForEach(notes.notes) { note in
                            NavigationLink {
                                NoteEditorView(note: note, notes: notes)
                            } label: {
                                NoteRow(note: note)
                            }
                        }
                        .onDelete { offsets in
                            Task { await notes.delete(at: offsets) }
                        }
                    }
                }
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !notes.notes.isEmpty {
                        ShareLink(item: notes.exportText) {
                            Image(systemName: "square.and.arrow.up")
                        }
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
            .task { await notes.load() }
        }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                Text(preview)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// First non-empty line becomes the title, like iOS Notes.
    private var title: String {
        note.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? "New Note"
    }

    /// The remainder after the title line, shown as a one-line preview.
    private var preview: String {
        let lines = note.text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return lines.count > 1 ? lines[1] : ""
    }
}

/// A minimal full-screen editor. Creating a new note (`note == nil`) saves on
/// exit; editing an existing note updates it, or deletes it if emptied.
struct NoteEditorView: View {
    let note: Note?
    @Bindable var notes: NotesViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .focused($focused)
            .padding(.horizontal)
            .navigationTitle(note == nil ? "New Note" : "Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task {
                            await commit()
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                text = note?.text ?? ""
                if note == nil { focused = true }
            }
    }

    private func commit() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let note {
            if trimmed.isEmpty {
                await notes.delete(note)
            } else if trimmed != note.text {
                await notes.update(note, text: trimmed)
            }
        } else if !trimmed.isEmpty {
            await notes.create(trimmed)
        }
    }
}
