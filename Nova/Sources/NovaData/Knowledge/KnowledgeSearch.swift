import Foundation
import NovaCore
import NovaDomain

/// Search across the user's notes, bookmarks, facts, and recent conversation.
/// Ranking blends keyword term-overlap with an optional on-device semantic
/// (embedding) score so relevant items surface even without exact keyword
/// overlap. Falls back to pure keyword ranking when embeddings are unavailable.
public struct KnowledgeSearch: KnowledgeSearching {
    private let notes: any NoteStoring
    private let bookmarks: any BookmarkStoring
    private let facts: FileFactStore
    private let memory: any ConversationMemory
    private let useSemantic: Bool

    /// Above this cosine (mapped to [0,1]) an item is included even with no
    /// keyword overlap; the bonus above the 0.5 baseline is weighted in.
    private let semanticThreshold = 0.62
    private let semanticWeight = 4.0

    public init(
        notes: any NoteStoring,
        bookmarks: any BookmarkStoring,
        facts: FileFactStore,
        memory: any ConversationMemory,
        useSemantic: Bool = true
    ) {
        self.notes = notes
        self.bookmarks = bookmarks
        self.facts = facts
        self.memory = memory
        self.useSemantic = useSemantic
    }

    private struct Candidate {
        let hit: KnowledgeHit
        let text: String
        let weight: Double
    }

    public func search(_ query: String, limit: Int = 8) async -> [KnowledgeHit] {
        let terms = Self.tokenize(query)
        guard !terms.isEmpty else { return [] }

        var candidates: [Candidate] = []
        for note in await notes.all() {
            candidates.append(Candidate(
                hit: KnowledgeHit(source: .note, title: Self.titleLine(note.text), snippet: Self.snippet(note.text, terms: terms), date: note.updatedAt),
                text: note.text, weight: 1.0))
        }
        for bm in await bookmarks.all() {
            candidates.append(Candidate(
                hit: KnowledgeHit(source: .bookmark, title: bm.title, snippet: Self.snippet(bm.text, terms: terms), date: bm.createdAt),
                text: bm.title + " " + bm.text, weight: 1.0))
        }
        for fact in await facts.all() {
            candidates.append(Candidate(
                hit: KnowledgeHit(source: .fact, title: "Fact", snippet: fact, date: .distantPast),
                text: fact, weight: 1.1))
        }
        for turn in await memory.recent(limit: 200) {
            candidates.append(Candidate(
                hit: KnowledgeHit(source: .conversation, title: turn.role.rawValue.capitalized, snippet: Self.snippet(turn.text, terms: terms), date: turn.at),
                text: turn.text, weight: 1.0))
        }

        // Build the embedding scorer locally (not stored — it wraps a class).
        let scorer: EmbeddingScorer? = useSemantic ? EmbeddingScorer() : nil
        let semanticOn = scorer?.isAvailable ?? false

        var scored: [(hit: KnowledgeHit, score: Double)] = []
        for candidate in candidates {
            let keyword = Self.score(text: candidate.text, terms: terms) * candidate.weight
            var combined = keyword
            var include = keyword > 0
            if semanticOn, let sim = scorer?.similarity(query, candidate.text) {
                combined += max(0, sim - 0.5) * semanticWeight
                if sim >= semanticThreshold { include = true }
            }
            if include { scored.append((candidate.hit, combined)) }
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
            .map { String($0) }
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
