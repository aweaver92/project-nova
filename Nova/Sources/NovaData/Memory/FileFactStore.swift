import Foundation
import NovaCore

/// Durable store of user "facts" (preferences, names, ongoing context) that Nova
/// should remember across sessions. Separate from conversation history so it can
/// be injected verbatim into each session's system instructions.
public actor FileFactStore {
    private let url: URL
    private let maxFacts: Int
    private var facts: [String]

    public init(url: URL? = nil, maxFacts: Int = 200) {
        self.maxFacts = maxFacts
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.facts = Self.load(from: resolved)
    }

    @discardableResult
    public func add(_ fact: String) -> Bool {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !facts.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        facts.append(trimmed)
        if facts.count > maxFacts { facts.removeFirst(facts.count - maxFacts) }
        persist()
        return true
    }

    public func all() -> [String] { facts }

    /// Removes facts containing `match` (case-insensitive). Returns how many.
    @discardableResult
    public func remove(matching match: String) -> Int {
        let needle = match.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return 0 }
        let before = facts.count
        facts.removeAll { $0.lowercased().contains(needle) }
        let removed = before - facts.count
        if removed > 0 { persist() }
        return removed
    }

    public func clear() {
        facts.removeAll()
        persist()
    }

    /// Bulleted list for injection into session instructions ("" if empty).
    public func summary() -> String {
        facts.isEmpty ? "" : facts.map { "- \($0)" }.joined(separator: "\n")
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(facts)
            try data.write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Fact persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-facts.json")
    }
}
