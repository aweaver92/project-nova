import Foundation
import NovaCore
import NovaDomain

/// Keyword-ranked search across the user's notes, bookmarks, facts, and recent
/// conversation. Phase 1 uses simple term-overlap scoring with a recency
/// tie-break; on-device embeddings are a future upgrade.
public struct KnowledgeSearch: KnowledgeSearching {
    private let notes: any NoteStoring
    private let bookmarks: any BookmarkStoring
    private let facts: FileFactStore
    private let memory: any ConversationMemory

    public init(
        notes: any NoteStoring,
        bookmarks: any BookmarkStoring,
        facts: FileFactStore,
        memory: any ConversationMemory
    ) {
        self.notes = notes
        self.bookmarks = bookmarks
        self.facts = facts
        self.memory = memory
    }

    public func search(_ query: String, limit: Int = 8) async -> [KnowledgeHit] {
        let terms = Self.tokenize(query)
        guard !terms.isEmpty else { return [] }

        var scored: [(hit: KnowledgeHit, score: Double)] = []

        for note in await notes.all() {
            let s = Self.score(text: note.text, terms: terms)
            if s > 0 {
                scored.append((KnowledgeHit(source: .note, title: Self.titleLine(note.text), snippet: Self.snippet(note.text, terms: terms), date: note.updatedAt), s))
            }
        }
        for bm in await bookmarks.all() {
            let s = Self.score(text: bm.title + " " + bm.text, terms: terms)
            if s > 0 {
                scored.append((KnowledgeHit(source: .bookmark, title: bm.title, snippet: Self.snippet(bm.text, terms: terms), date: bm.createdAt), s))
            }
        }
        for fact in await facts.all() {
            let s = Self.score(text: fact, terms: terms)
            if s > 0 {
                scored.append((KnowledgeHit(source: .fact, title: "Fact", snippet: fact, date: .distantPast), s * 1.1))
            }
        }
        for turn in await memory.recent(limit: 200) {
            let s = Self.score(text: turn.text, terms: terms)
            if s > 0 {
                scored.append((KnowledgeHit(source: .conversation, title: turn.role.rawValue.capitalized, snippet: Self.snippet(turn.text, terms: terms), date: turn.at), s))
            }
        }

        return scored
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.hit.date > rhs.hit.date : lhs.score > rhs.score
            }
            .prefix(limit)
            .map(\.hit)
    }

    // MARK: - Scoring

    private static let stopwords: Set<String> = [
        "the", "a", "an", "of", "to", "in", "on", "for", "and", "or", "is", "are",
        "was", "were", "did", "do", "i", "my", "me", "when", "what", "where", "how",
        "find", "search", "that", "this", "it", "with", "about"
    ]

    static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0) }
    }

    /// Sum of term hits; multi-term matches rank higher.
    static func score(text: String, terms: [String]) -> Double {
        let hay = text.lowercased()
        var total = 0.0
        for term in terms where hay.contains(term) { total += 1 }
        return total
    }

    private static func titleLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "Note"
    }

    /// A short snippet centered on the first matching term.
    private static func snippet(_ text: String, terms: [String]) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let lower = flat.lowercased()
        guard let term = terms.first(where: { lower.contains($0) }),
              let range = lower.range(of: term) else {
            return String(flat.prefix(120))
        }
        let start = flat.index(range.lowerBound, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: 80, limitedBy: flat.endIndex) ?? flat.endIndex
        return String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
    }
}
