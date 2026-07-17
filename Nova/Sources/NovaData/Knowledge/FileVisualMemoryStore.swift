import Foundation
import NovaCore
import NovaDomain

/// File-backed store for Nova's visual memory. Images live under
/// `Documents/VisualMemory` with a JSON metadata index, so sightings persist on
/// the iPhone and are exportable from the Files app.
public actor FileVisualMemoryStore: VisualMemoryStoring {
    private let dir: URL
    private let indexURL: URL
    private var items: [VisualMemoryItem]
    /// Cap so the life log can't grow without bound; oldest are pruned first.
    private let maxItems: Int

    public init(directory: URL? = nil, maxItems: Int = 2_000) {
        let resolved = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        self.dir = resolved
        self.indexURL = resolved.appendingPathComponent("index.json")
        self.items = Self.load(from: indexURL)
        self.maxItems = maxItems
    }

    public func directory() -> URL { dir }

    @discardableResult
    public func save(imageData: Data, text: String, caption: String, workspaceId: UUID?) -> VisualMemoryItem {
        let id = UUID()
        let fileName = "nova-vismem-\(id.uuidString).jpg"
        try? imageData.write(to: dir.appendingPathComponent(fileName), options: .atomic)
        let item = VisualMemoryItem(
            id: id,
            fileName: fileName,
            text: text,
            caption: caption,
            workspaceId: workspaceId
        )
        items.append(item)
        pruneIfNeeded()
        persist()
        return item
    }

    public func all() -> [VisualMemoryItem] { items }

    public func delete(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: idx)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(removed.fileName))
        persist()
    }

    public func clear() {
        for item in items {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.fileName))
        }
        items.removeAll()
        persist()
    }

    private func pruneIfNeeded() {
        guard items.count > maxItems else { return }
        let overflow = items.count - maxItems
        let removed = items.prefix(overflow)
        for item in removed {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.fileName))
        }
        items.removeFirst(overflow)
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NovaLog.session.error("Visual memory index persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [VisualMemoryItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([VisualMemoryItem].self, from: data)) ?? []
    }

    private static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("VisualMemory", isDirectory: true)
    }
}
