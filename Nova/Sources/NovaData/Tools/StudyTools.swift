import Foundation
import NovaDomain

enum StudyToolJSON {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

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
        return #"{"ok":true,"id":"\#(card.id.uuidString)","deck":"\#(StudyToolJSON.escape(card.deck))"}"#
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
        let due = await store.due(deck: nil, limit: 500)
        let byDeck = Dictionary(grouping: due, by: \.deck)
        let items: [[String: Any]] = decks.map { name in
            ["name": name, "due": byDeck[name]?.count ?? 0]
        }
        return try StudyToolJSON.encode([
            "ok": true,
            "decks": items,
            "due_total": due.count
        ])
    }
}

public struct ListStudyCardsTool: Tool {
    public let name = "list_study_cards"
    public let description = "List cards in a study deck (front, back, due date)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"deck":{"type":"string"},"limit":{"type":"integer"}},"required":["deck"],"additionalProperties":false}
    """
    private let store: any StudyDeckStoring
    public init(store: any StudyDeckStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let deck: String; let limit: Int? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let limit = max(1, args.limit ?? 50)
        let cards = await store.all()
            .filter { $0.deck.localizedCaseInsensitiveCompare(args.deck) == .orderedSame }
            .prefix(limit)
        let iso = ISO8601DateFormatter()
        let items: [[String: Any]] = cards.map {
            [
                "id": $0.id.uuidString,
                "deck": $0.deck,
                "front": $0.front,
                "back": $0.back,
                "due_at": iso.string(from: $0.dueAt),
                "interval_days": $0.intervalDays,
                "repetitions": $0.repetitions
            ]
        }
        return try StudyToolJSON.encode([
            "ok": true,
            "deck": args.deck,
            "count": items.count,
            "cards": items
        ])
    }
}

public struct UpdateStudyCardTool: Tool {
    public let name = "update_study_card"
    public let description = "Edit a study card's front, back, and/or deck."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"id":{"type":"string"},"front":{"type":"string"},"back":{"type":"string"},"deck":{"type":"string"}},"required":["id"],"additionalProperties":false}
    """
    private let store: any StudyDeckStoring
    public init(store: any StudyDeckStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let id: String
            let front: String?
            let back: String?
            let deck: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let id = UUID(uuidString: args.id),
              var card = await store.card(id: id) else {
            return #"{"ok":false,"error":"card_not_found"}"#
        }
        if let front = args.front, !front.isEmpty { card.front = front }
        if let back = args.back, !back.isEmpty { card.back = back }
        if let deck = args.deck, !deck.isEmpty { card.deck = deck }
        let saved = await store.upsert(card)
        return try StudyToolJSON.encode([
            "ok": true,
            "id": saved.id.uuidString,
            "deck": saved.deck,
            "front": saved.front,
            "back": saved.back
        ])
    }
}

public struct DeleteStudyCardTool: Tool {
    public let name = "delete_study_card"
    public let description = "Delete a study card by id."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}
    """
    private let store: any StudyDeckStoring
    public init(store: any StudyDeckStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let id: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let id = UUID(uuidString: args.id) else {
            return #"{"ok":false,"error":"invalid_id"}"#
        }
        guard await store.card(id: id) != nil else {
            return #"{"ok":false,"error":"card_not_found"}"#
        }
        await store.delete(id: id)
        return #"{"ok":true,"id":"\#(id.uuidString)"}"#
    }
}

public struct StartQuizTool: Tool {
    public let name = "start_quiz"
    public let description = "Start a quiz session: returns due cards (front only). After the user answers, call reveal_card, then grade_card."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"deck":{"type":"string","description":"Optional deck filter."},"limit":{"type":"integer"}},"additionalProperties":false}
    """
    private let store: any StudyDeckStoring
    public init(store: any StudyDeckStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let deck: String?; let limit: Int? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(deck: nil, limit: nil)
        let due = await store.due(deck: args.deck, limit: args.limit ?? 10)
        let cards: [[String: Any]] = due.map {
            [
                "id": $0.id.uuidString,
                "deck": $0.deck,
                "front": $0.front
            ]
        }
        return try StudyToolJSON.encode(["ok": true, "count": cards.count, "cards": cards])
    }
}

public struct RevealCardTool: Tool {
    public let name = "reveal_card"
    public let description = "After the learner answers a quiz card, reveal the stored back/answer (does not grade or reschedule)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}
    """
    private let store: any StudyDeckStoring
    public init(store: any StudyDeckStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let id: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let id = UUID(uuidString: args.id),
              let card = await store.card(id: id) else {
            return #"{"ok":false,"error":"card_not_found"}"#
        }
        return try StudyToolJSON.encode([
            "ok": true,
            "id": card.id.uuidString,
            "deck": card.deck,
            "front": card.front,
            "back": card.back
        ])
    }
}

public struct GradeCardTool: Tool {
    public let name = "grade_card"
    public let description = "After reveal_card and discussion, grade the card: again, hard, good, or easy. Schedules the next review. Optionally echo the learner's answer."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"id":{"type":"string"},"grade":{"type":"string","enum":["again","hard","good","easy"]},"user_answer":{"type":"string"}},"required":["id","grade"],"additionalProperties":false}
    """
    private let store: any StudyDeckStoring
    public init(store: any StudyDeckStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let id: String; let grade: String; let user_answer: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let id = UUID(uuidString: args.id),
              let grade = StudyGrade(rawValue: args.grade.lowercased()) else {
            return #"{"ok":false,"error":"invalid_id_or_grade"}"#
        }
        guard let card = await store.grade(id: id, grade: grade) else {
            return #"{"ok":false,"error":"card_not_found"}"#
        }
        var result: [String: Any] = [
            "ok": true,
            "id": card.id.uuidString,
            "back": card.back,
            "grade": grade.rawValue,
            "next_interval_days": card.intervalDays,
            "due_at": ISO8601DateFormatter().string(from: card.dueAt)
        ]
        if let answer = args.user_answer {
            result["user_answer"] = answer
        }
        return try StudyToolJSON.encode(result)
    }
}
