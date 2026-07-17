import Foundation
import NovaCore
import NovaDomain

/// File-backed long-term memory digest, keyed per workspace. The digest is a
/// compact running summary of older turns so context survives beyond the rolling
/// conversation window without bloating the prompt.
public actor FileMemoryDigestStore: MemoryDigestStoring {
    private struct Entry: Codable {
        var digest: String
        var coveredThrough: Date
    }

    private let url: URL
    private var entries: [String: Entry]

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.entries = Self.load(from: resolved)
    }

    /// Global bucket key for the nil (unscoped) workspace.
    private func key(_ workspaceId: UUID?) -> String {
        workspaceId?.uuidString ?? "__global__"
    }

    public func digest(workspaceId: UUID?) -> String {
        entries[key(workspaceId)]?.digest ?? ""
    }

    public func setDigest(_ text: String, coveredThrough: Date, workspaceId: UUID?) {
        entries[key(workspaceId)] = Entry(digest: text, coveredThrough: coveredThrough)
        persist()
    }

    public func coveredThrough(workspaceId: UUID?) -> Date? {
        entries[key(workspaceId)]?.coveredThrough
    }

    private func persist() {
        do {
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Digest persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-memory-digest.json")
    }
}
