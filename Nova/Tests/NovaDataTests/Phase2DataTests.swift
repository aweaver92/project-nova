import XCTest
@testable import NovaCore
@testable import NovaData
@testable import NovaDomain

// MARK: - Memory digest store

final class MemoryDigestStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-digest-\(UUID().uuidString).json")
    }

    func testSetGetAndScopingPersist() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let wsA = UUID()
        let wsB = UUID()
        let store = FileMemoryDigestStore(url: url)

        XCTAssertEqual(await store.digest(workspaceId: wsA), "")
        XCTAssertNil(await store.coveredThrough(workspaceId: wsA))

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        await store.setDigest("A digest", coveredThrough: date, workspaceId: wsA)
        await store.setDigest("B digest", coveredThrough: date, workspaceId: wsB)

        // Scoped correctly and survives a reload.
        let reloaded = FileMemoryDigestStore(url: url)
        XCTAssertEqual(await reloaded.digest(workspaceId: wsA), "A digest")
        XCTAssertEqual(await reloaded.digest(workspaceId: wsB), "B digest")
        XCTAssertEqual(await reloaded.coveredThrough(workspaceId: wsA), date)
        // Unknown workspace is empty.
        XCTAssertEqual(await reloaded.digest(workspaceId: UUID()), "")
    }
}

// MARK: - Memory compactor

final class MemoryCompactorTests: XCTestCase {
    func testDoesNotCompactBelowThreshold() async {
        let memory = InMemoryConversationMemory()
        for i in 0..<3 {
            await memory.append(ConversationTurn(role: .user, text: "turn \(i)", at: Date(timeIntervalSince1970: Double(i))))
        }
        let digestStore = FileMemoryDigestStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mc-\(UUID().uuidString).json"))
        let summarizer = CountingSummarizer()
        let compactor = MemoryCompactor(memory: memory, digestStore: digestStore, summarizer: summarizer, threshold: 5)

        await compactor.compactIfNeeded(workspaceId: nil)
        XCTAssertEqual(await summarizer.calls, 0)
        XCTAssertEqual(await digestStore.digest(workspaceId: nil), "")
    }

    func testCompactsWhenThresholdMetAndAdvancesCoverage() async {
        let memory = InMemoryConversationMemory()
        var last = Date(timeIntervalSince1970: 0)
        for i in 0..<4 {
            last = Date(timeIntervalSince1970: Double(i + 1))
            await memory.append(ConversationTurn(role: .user, text: "turn \(i)", at: last))
        }
        let digestStore = FileMemoryDigestStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mc-\(UUID().uuidString).json"))
        let summarizer = CountingSummarizer()
        let compactor = MemoryCompactor(memory: memory, digestStore: digestStore, summarizer: summarizer, threshold: 3)

        await compactor.compactIfNeeded(workspaceId: nil)
        XCTAssertEqual(await summarizer.calls, 1)
        XCTAssertEqual(await digestStore.digest(workspaceId: nil), "digest#1")
        XCTAssertEqual(await digestStore.coveredThrough(workspaceId: nil), last)

        // No new turns → no second compaction.
        await compactor.compactIfNeeded(workspaceId: nil)
        XCTAssertEqual(await summarizer.calls, 1)
    }
}

private actor CountingSummarizer: MemorySummarizing {
    private(set) var calls = 0
    func summarize(previousDigest: String, turns: [ConversationTurn]) async -> String {
        calls += 1
        return "digest#\(calls)"
    }
}

// MARK: - Embedding scorer (semantic ranking helper)

final class EmbeddingScorerTests: XCTestCase {
    func testCosineIdenticalIsOne() {
        XCTAssertEqual(EmbeddingScorer.cosine([1, 2, 3], [1, 2, 3]), 1, accuracy: 0.0001)
    }

    func testCosineOppositeIsZero() {
        XCTAssertEqual(EmbeddingScorer.cosine([1, 0], [-1, 0]), 0, accuracy: 0.0001)
    }

    func testCosineOrthogonalIsHalf() {
        // Orthogonal vectors map to the 0.5 baseline (no positive/negative signal).
        XCTAssertEqual(EmbeddingScorer.cosine([1, 0], [0, 1]), 0.5, accuracy: 0.0001)
    }

    func testEmptyVectorsAreZero() {
        XCTAssertEqual(EmbeddingScorer.cosine([], []), 0)
    }
}

// MARK: - Settings store

final class SettingsStoreTests: XCTestCase {
    func testSpokenFollowUpsRoundTrips() async {
        let suite = "nova.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertFalse(await store.spokenFollowUps())

        await store.setSpokenFollowUps(true)
        XCTAssertTrue(await store.spokenFollowUps())

        // A fresh store over the same suite reads the persisted value.
        let reloaded = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertTrue(await reloaded.spokenFollowUps())
    }
}

// MARK: - Skill import/export contract (Codable round-trip incl. schedule)

final class SkillCodableTests: XCTestCase {
    func testSkillWithScheduleRoundTrips() throws {
        let skill = Skill(
            name: "Morning brief",
            triggerPhrases: ["morning brief"],
            steps: [SkillStep(kind: .freeform, text: "give me the briefing")],
            schedule: SkillSchedule(hour: 7, minute: 30, weekdays: [2, 3, 4, 5, 6])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(skill)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Skill.self, from: data)

        XCTAssertEqual(decoded.name, skill.name)
        XCTAssertEqual(decoded.triggerPhrases, skill.triggerPhrases)
        XCTAssertEqual(decoded.schedule?.hour, 7)
        XCTAssertEqual(decoded.schedule?.minute, 30)
        XCTAssertEqual(decoded.schedule?.weekdays, [2, 3, 4, 5, 6])
        XCTAssertEqual(decoded.steps.first?.text, "give me the briefing")
    }
}
