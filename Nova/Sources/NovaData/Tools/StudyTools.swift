import Foundation
import NovaDomain

public struct AddStudyCardTool: Tool {
    public let name = "add_study_card"
    public let description = "Add a flashcard to a study deck (front/question, back/answer)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"deck":{"type":"string"},"front":{"type":"string"},"back":{"type":"string"}},"required":["deck","front","back"],"additionalProperties":false}
    """
    private let store: any StudyDeckStoring
    public init(store: any StudyDeckStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let deck: String; let front: String; let back: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let card = await store.upsert(StudyCard(deck: args.deck, front: args.front, back: args.back))
        return #"{"ok":true,"id":"\#(card.id.uuidString)","deck":"\#(Self.escape(card.deck))"}"#
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public struct ListStudyDecksTool: Tool {
    public let name = "list_study_decks"
    public let description = "List study deck names and how many cards are due."
    public let requiresConfirmation = false
    private let store: any StudyDeckStoring
    public init(store: any StudyDeckStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        let decks = await store.decks()
        let due = await store.due(limit: 500)
        let byDeck = Dictionary(grouping: due, by: \.deck)
        let items: [[String: Any]] = decks.map { name in
            ["name": name, "due": byDeck[name]?.count ?? 0]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "decks": items,
            "due_total": due.count
        ])
        return String(decoding: data, as: UTF8.self)
    }
}

public struct StartQuizTool: Tool {
    public let name = "start_quiz"
    public let description = "Start a quiz session: returns due cards (front only — do not reveal the back until the user answers, then call grade_card)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"deck":{"type":"string","description":"Optional deck filter."},"limit":{"type":"integer"}},"additionalProperties":false}
    """
    private let store: any StudyDeckStoring
    public init(store: any StudyDeckStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let deck: String?; let limit: Int? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(deck: nil, limit: nil)
        var due = await store.due(limit: args.limit ?? 10)
        if let deck = args.deck, !deck.isEmpty {
            due = due.filter { $0.deck.localizedCaseInsensitiveCompare(deck) == .orderedSame }
        }
        let cards: [[String: Any]] = due.map {
            [
                "id": $0.id.uuidString,
                "deck": $0.deck,
                "front": $0.front
                // intentionally omit back so the model quizzes first
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "count": cards.count, "cards": cards])
        return String(decoding: data, as: UTF8.self)
    }
}

public struct GradeCardTool: Tool {
    public let name = "grade_card"
    public let description = "After the user answers a quiz card, reveal/confirm the answer and grade it: again, hard, good, or easy. Schedules the next review."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"id":{"type":"string"},"grade":{"type":"string","enum":["again","hard","good","easy"]}},"required":["id","grade"],"additionalProperties":false}
    """
    private let store: any StudyDeckStoring
    public init(store: any StudyDeckStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let id: String; let grade: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let id = UUID(uuidString: args.id),
              let grade = StudyGrade(rawValue: args.grade.lowercased()) else {
            return #"{"ok":false,"error":"invalid_id_or_grade"}"#
        }
        guard let card = await store.grade(id: id, grade: grade) else {
            return #"{"ok":false,"error":"card_not_found"}"#
        }
        return #"{"ok":true,"id":"\#(card.id.uuidString)","back":"\#(Self.escape(card.back))","next_interval_days":\#(card.intervalDays),"due_at":"\#(ISO8601DateFormatter().string(from: card.dueAt))"}"#
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
