import Foundation
import NovaCore
import NovaDomain

/// File-backed voice notes, persisted as JSON in the app container.
public actor FileNoteStore: NoteStoring {
    private let url: URL
    private var notes: [Note]

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.notes = Self.load(from: resolved)
    }

    @discardableResult
    public func save(_ text: String) -> Note {
        let note = Note(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        notes.append(note)
        persist()
        return note
    }

    public func all() -> [Note] { notes }

    public func clear() {
        notes.removeAll()
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(notes)
            try data.write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Note persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [Note] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Note].self, from: data)) ?? []
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-notes.json")
    }
}
