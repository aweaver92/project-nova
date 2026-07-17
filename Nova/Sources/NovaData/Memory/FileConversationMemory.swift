import Foundation
import NovaCore
import NovaDomain

/// File-backed `ConversationMemory` so Nova retains context across reconnects and
/// app launches. Turns are stored as JSON in the app container and loaded on init.
public actor FileConversationMemory: ConversationMemory {
    private let url: URL
    private let maxTurns: Int
    private let summaryTurns: Int
    private var turns: [ConversationTurn]

    /// - Parameters:
    ///   - url: Storage location; defaults to Application Support.
    ///   - maxTurns: Cap on retained turns to bound file/prompt size.
    ///   - summaryTurns: How many recent turns `summary()` injects into a session.
    public init(url: URL? = nil, maxTurns: Int = 200, summaryTurns: Int = 12) {
        self.maxTurns = maxTurns
        self.summaryTurns = summaryTurns
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.turns = Self.load(from: resolved)
    }

    public func append(_ turn: ConversationTurn) async {
        turns.append(turn)
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
        persist()
    }

    public func recent(limit: Int) async -> [ConversationTurn] {
        Array(turns.suffix(limit))
    }

    public func summary() async -> String {
        turns.suffix(summaryTurns)
            .map { "\($0.role.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }

    public func clear() async {
        turns.removeAll()
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(turns)
            try data.write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Memory persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [ConversationTurn] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ConversationTurn].self, from: data)) ?? []
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-conversation.json")
    }
}
