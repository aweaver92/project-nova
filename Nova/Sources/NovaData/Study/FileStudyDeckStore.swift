import Foundation
import NovaCore
import NovaDomain

/// File-backed spaced-repetition cards for Scholar (SM-2-lite).
public actor FileStudyDeckStore: StudyDeckStoring {
    private let url: URL
    private var cards: [StudyCard]

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.cards = Self.load(from: resolved)
    }

    public func all() -> [StudyCard] {
        cards.sorted { $0.dueAt < $1.dueAt }
    }

    public func decks() -> [String] {
        Array(Set(cards.map(\.deck))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func due(deck: String?, limit: Int) -> [StudyCard] {
        let now = Date()
        var due = cards.filter { $0.dueAt <= now }
        if let deck, !deck.isEmpty {
            due = due.filter { $0.deck.localizedCaseInsensitiveCompare(deck) == .orderedSame }
        }
        return Array(due.sorted { $0.dueAt < $1.dueAt }.prefix(max(0, limit)))
    }

    public func card(id: UUID) -> StudyCard? {
        cards.first { $0.id == id }
    }

    @discardableResult
    public func upsert(_ card: StudyCard) -> StudyCard {
        if let idx = cards.firstIndex(where: { $0.id == card.id }) {
            cards[idx] = card
        } else {
            cards.append(card)
        }
        persist()
        return card
    }

    @discardableResult
    public func grade(id: UUID, grade: StudyGrade) -> StudyCard? {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return nil }
        var card = cards[idx]
        card = Self.apply(grade: grade, to: card)
        cards[idx] = card
        persist()
        return card
    }

    public func delete(id: UUID) {
        cards.removeAll { $0.id == id }
        persist()
    }

    public func summary(dueLimit: Int) -> String {
        let dueCards = due(deck: nil, limit: dueLimit)
        let deckNames = decks()
        guard !dueCards.isEmpty || !deckNames.isEmpty else { return "" }
        var lines: [String] = []
        if !deckNames.isEmpty {
            lines.append("Study decks: \(deckNames.joined(separator: ", ")).")
        }
        if dueCards.isEmpty {
            lines.append("No study cards are due right now.")
        } else {
            lines.append("Due cards (\(dueCards.count)):")
            for c in dueCards.prefix(dueLimit) {
                lines.append("- [\(c.deck)] \(c.front) (id \(c.id.uuidString.prefix(8)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Simplified SM-2: again resets; hard/good/easy grow interval by ease.
    static func apply(grade: StudyGrade, to card: StudyCard) -> StudyCard {
        var next = card
        switch grade {
        case .again:
            next.repetitions = 0
            next.intervalDays = 0
            next.ease = max(1.3, next.ease - 0.2)
            next.dueAt = Date()
        case .hard:
            next.repetitions += 1
            next.ease = max(1.3, next.ease - 0.15)
            next.intervalDays = max(1, next.intervalDays * 1.2)
            if next.repetitions == 1 { next.intervalDays = 1 }
            next.dueAt = Date().addingTimeInterval(next.intervalDays * 86_400)
        case .good:
            next.repetitions += 1
            if next.repetitions == 1 {
                next.intervalDays = 1
            } else if next.repetitions == 2 {
                next.intervalDays = 3
            } else {
                next.intervalDays = max(1, next.intervalDays * next.ease)
            }
            next.dueAt = Date().addingTimeInterval(next.intervalDays * 86_400)
        case .easy:
            next.repetitions += 1
            next.ease += 0.15
            if next.repetitions == 1 {
                next.intervalDays = 2
            } else if next.repetitions == 2 {
                next.intervalDays = 5
            } else {
                next.intervalDays = max(1, next.intervalDays * next.ease * 1.3)
            }
            next.dueAt = Date().addingTimeInterval(next.intervalDays * 86_400)
        }
        return next
    }

    private func persist() {
        do {
            try JSONEncoder().encode(cards).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Study deck persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [StudyCard] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([StudyCard].self, from: data)) ?? []
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-study-decks.json")
    }
}
