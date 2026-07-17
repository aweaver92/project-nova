import Foundation
import NovaCore
import NovaDomain

/// File-backed storage for conversation bookmarks.
public actor FileBookmarkStore: BookmarkStoring {
    private let url: URL
    private var bookmarks: [Bookmark]

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.bookmarks = Self.load(from: resolved)
    }

    @discardableResult
    public func save(_ bookmark: Bookmark) -> Bookmark {
        bookmarks.append(bookmark)
        persist()
        return bookmark
    }

    public func all() -> [Bookmark] {
        bookmarks.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    public func clear() {
        bookmarks.removeAll()
        persist()
    }

    private func persist() {
        do {
            try JSONEncoder().encode(bookmarks).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Bookmark persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [Bookmark] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Bookmark].self, from: data)) ?? []
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-bookmarks.json")
    }
}
