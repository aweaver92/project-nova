import Foundation
import NovaDomain
import Observation

public struct StudyDeckSummary: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let totalCount: Int
    public let dueCount: Int

    public init(name: String, totalCount: Int, dueCount: Int) {
        self.name = name
        self.totalCount = totalCount
        self.dueCount = dueCount
    }
}

public enum StudyDeepLink: Sendable, Equatable {
    case startReview(deck: String?)
}

@MainActor
@Observable
public final class StudyViewModel {
    public private(set) var deckSummaries: [StudyDeckSummary] = []
    public private(set) var dueTotal: Int = 0
    public private(set) var selectedDeckName: String?
    public private(set) var selectedDeckCards: [StudyCard] = []
    public private(set) var reviewQueue: [StudyCard] = []
    public private(set) var reviewIndex: Int = 0
    public private(set) var isRevealed = false
    public private(set) var isReviewing = false
    public private(set) var shouldPresentStudy = false
    public private(set) var pendingDeepLink: StudyDeepLink?

    /// True while Study is on-screen (drives polling for voice quiz sync).
    public private(set) var isScreenVisible = false

    private let store: any StudyDeckStoring
    private var pollTask: Task<Void, Never>?

    public init(store: any StudyDeckStoring) {
        self.store = store
    }

    public var hasDecks: Bool { !deckSummaries.isEmpty }

    public var currentReviewCard: StudyCard? {
        guard isReviewing, reviewIndex < reviewQueue.count else { return nil }
        return reviewQueue[reviewIndex]
    }

    public var reviewProgressLabel: String {
        guard !reviewQueue.isEmpty else { return "" }
        return "Card \(min(reviewIndex + 1, reviewQueue.count)) of \(reviewQueue.count)"
    }

    public func setScreenVisible(_ visible: Bool) {
        isScreenVisible = visible
        updatePolling()
    }

    public func load() async {
        await refresh()
        updatePolling()
    }

    private func refresh() async {
        let all = await store.all()
        let due = await store.due(deck: nil, limit: 500)
        dueTotal = due.count
        let decks = await store.decks()
        deckSummaries = decks.map { name in
            let total = all.filter { $0.deck.localizedCaseInsensitiveCompare(name) == .orderedSame }.count
            let dueCount = due.filter { $0.deck.localizedCaseInsensitiveCompare(name) == .orderedSame }.count
            return StudyDeckSummary(name: name, totalCount: total, dueCount: dueCount)
        }
        if let selectedDeckName {
            selectedDeckCards = all.filter { $0.deck.localizedCaseInsensitiveCompare(selectedDeckName) == .orderedSame }
        }
        // Keep an open UI review queue honest with store after voice grades.
        if isReviewing {
            await reconcileReviewQueue(dueCards: due)
        }
    }

    public func selectDeck(_ name: String) async {
        selectedDeckName = name
        let all = await store.all()
        selectedDeckCards = all.filter { $0.deck.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    public func upsertCard(_ card: StudyCard) async {
        _ = await store.upsert(card)
        await load()
        if let selectedDeckName {
            await selectDeck(selectedDeckName)
        }
    }

    public func deleteCard(id: UUID) async {
        await store.delete(id: id)
        await load()
        if let selectedDeckName {
            await selectDeck(selectedDeckName)
        }
    }

    public func startReview(deck: String? = nil) async {
        let queue = await store.due(deck: deck, limit: 50)
        guard !queue.isEmpty else {
            isReviewing = false
            reviewQueue = []
            reviewIndex = 0
            isRevealed = false
            return
        }
        reviewQueue = queue
        reviewIndex = 0
        isRevealed = false
        isReviewing = true
        if let deck {
            selectedDeckName = deck
        }
        updatePolling()
    }

    public func revealCurrent() {
        isRevealed = true
    }

    public func gradeCurrent(_ grade: StudyGrade) async {
        guard let card = currentReviewCard else { return }
        _ = await store.grade(id: card.id, grade: grade)
        isRevealed = false
        let next = reviewIndex + 1
        if next >= reviewQueue.count {
            isReviewing = false
            reviewQueue = []
            reviewIndex = 0
            await load()
        } else {
            reviewIndex = next
            await load()
        }
    }

    public func endReview() {
        isReviewing = false
        reviewQueue = []
        reviewIndex = 0
        isRevealed = false
        updatePolling()
    }

    public func requestStartReview(deck: String?) {
        pendingDeepLink = .startReview(deck: deck)
        shouldPresentStudy = true
    }

    public func clearPresentFlag() {
        shouldPresentStudy = false
    }

    public func consumeDeepLink() async {
        guard let link = pendingDeepLink else { return }
        pendingDeepLink = nil
        shouldPresentStudy = false
        switch link {
        case .startReview(let deck):
            await startReview(deck: deck)
        }
    }

    /// Voice `reveal_card` — reveal UI card when it matches.
    public func syncRevealFromVoice(cardId: UUID) {
        if currentReviewCard?.id == cardId {
            isRevealed = true
        }
    }

    /// Voice `grade_card` — advance or rebuild the single shared review queue.
    public func syncGradeFromVoice(cardId: UUID) async {
        if isReviewing, currentReviewCard?.id == cardId {
            isRevealed = false
            let next = reviewIndex + 1
            if next >= reviewQueue.count {
                endReview()
            } else {
                reviewIndex = next
            }
        }
        await load()
    }

    private func reconcileReviewQueue(dueCards: [StudyCard]) async {
        guard isReviewing else { return }
        // Drop cards no longer due (already graded by voice).
        let dueIds = Set(dueCards.map(\.id))
        let remaining = reviewQueue.filter { dueIds.contains($0.id) }
        if remaining.isEmpty {
            endReview()
            return
        }
        if let current = currentReviewCard, dueIds.contains(current.id) {
            // Keep index pointing at the same card if still due.
            if let idx = remaining.firstIndex(where: { $0.id == current.id }) {
                reviewQueue = remaining
                reviewIndex = idx
                return
            }
        }
        reviewQueue = remaining
        reviewIndex = min(reviewIndex, remaining.count - 1)
    }

    private func updatePolling() {
        let shouldPoll = isScreenVisible || isReviewing
        if !shouldPoll {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await self.refresh()
                if !self.isScreenVisible && !self.isReviewing {
                    self.pollTask = nil
                    return
                }
            }
        }
    }
}
