import XCTest
@testable import NovaDomain
@testable import NovaFeatures

@MainActor
final class StudyViewModelTests: XCTestCase {
    func testReviewSessionRevealAndGradeDropsDueCount() async {
        let store = InMemoryStudyDeckStore()
        _ = await store.upsert(StudyCard(deck: "Math", front: "2+2?", back: "4"))
        _ = await store.upsert(StudyCard(deck: "Math", front: "3+3?", back: "6"))

        let vm = StudyViewModel(store: store)
        await vm.load()
        XCTAssertEqual(vm.dueTotal, 2)

        await vm.startReview(deck: "Math")
        XCTAssertTrue(vm.isReviewing)
        XCTAssertEqual(vm.reviewQueue.count, 2)
        XCTAssertFalse(vm.isRevealed)

        vm.revealCurrent()
        XCTAssertTrue(vm.isRevealed)
        XCTAssertEqual(vm.currentReviewCard?.back, "4")

        await vm.gradeCurrent(.good)
        XCTAssertEqual(vm.reviewIndex, 1)
        XCTAssertFalse(vm.isRevealed)

        await vm.gradeCurrent(.easy)
        XCTAssertFalse(vm.isReviewing)
        XCTAssertEqual(vm.dueTotal, 0)
    }

    func testDeepLinkStartReview() async {
        let store = InMemoryStudyDeckStore()
        _ = await store.upsert(StudyCard(deck: "Bio", front: "Cell?", back: "Unit of life"))
        let vm = StudyViewModel(store: store)
        vm.requestStartReview(deck: "Bio")
        XCTAssertTrue(vm.shouldPresentStudy)
        XCTAssertEqual(vm.pendingDeepLink, .startReview(deck: "Bio"))

        await vm.consumeDeepLink()
        XCTAssertNil(vm.pendingDeepLink)
        XCTAssertTrue(vm.isReviewing)
        XCTAssertEqual(vm.currentReviewCard?.front, "Cell?")
    }
}

/// Minimal in-memory store for StudyViewModel tests (mirrors SM-2-lite scheduling).
actor InMemoryStudyDeckStore: StudyDeckStoring {
    private var cards: [StudyCard] = []

    func all() -> [StudyCard] { cards.sorted { $0.dueAt < $1.dueAt } }

    func decks() -> [String] {
        Array(Set(cards.map(\.deck))).sorted()
    }

    func due(deck: String?, limit: Int) -> [StudyCard] {
        let now = Date()
        var due = cards.filter { $0.dueAt <= now }
        if let deck, !deck.isEmpty {
            due = due.filter { $0.deck.localizedCaseInsensitiveCompare(deck) == .orderedSame }
        }
        return Array(due.sorted { $0.dueAt < $1.dueAt }.prefix(max(0, limit)))
    }

    func card(id: UUID) -> StudyCard? { cards.first { $0.id == id } }

    func upsert(_ card: StudyCard) -> StudyCard {
        if let idx = cards.firstIndex(where: { $0.id == card.id }) {
            cards[idx] = card
        } else {
            cards.append(card)
        }
        return card
    }

    func grade(id: UUID, grade: StudyGrade) -> StudyCard? {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return nil }
        var next = cards[idx]
        switch grade {
        case .again:
            next.repetitions = 0
            next.intervalDays = 0
            next.dueAt = Date()
        case .hard, .good, .easy:
            next.repetitions += 1
            next.intervalDays = grade == .easy ? 2 : 1
            next.dueAt = Date().addingTimeInterval(next.intervalDays * 86_400)
        }
        cards[idx] = next
        return next
    }

    func delete(id: UUID) {
        cards.removeAll { $0.id == id }
    }

    func summary(dueLimit: Int) -> String {
        let dueCards = due(deck: nil, limit: dueLimit)
        return "due:\(dueCards.count)"
    }
}
