import Foundation
import NovaCore
import NovaDomain

/// File-backed store for saved glasses video recordings.
///
/// Movie files and their metadata index live under `Documents/Videos`, so the
/// videos persist on the iPhone and — with `UIFileSharingEnabled` /
/// `LSSupportsOpeningDocumentsInPlace` set — are visible and exportable from the
/// Files app.
public actor FileVideoRecordingStore: VideoRecordingStoring {
    private let dir: URL
    private let indexURL: URL
    private var items: [VideoRecording]

    public init(directory: URL? = nil) {
        let resolved = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        self.dir = resolved
        self.indexURL = resolved.appendingPathComponent("index.json")
        self.items = Self.load(from: indexURL)
    }

    public func directory() -> URL { dir }

    @discardableResult
    public func register(_ recording: VideoRecording) -> VideoRecording {
        items.append(recording)
        persist()
        return recording
    }

    public func all() -> [VideoRecording] { items }

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

    @discardableResult
    public func pruneOlderThan(days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86_400)
        let stale = items.filter { $0.createdAt < cutoff }
        for item in stale { delete(id: item.id) }
        return stale.count
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NovaLog.session.error("Video index persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [VideoRecording] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([VideoRecording].self, from: data)) ?? []
    }

    private static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("Videos", isDirectory: true)
    }
}
