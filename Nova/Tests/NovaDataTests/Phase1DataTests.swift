import XCTest
@testable import NovaCore
@testable import NovaData
@testable import NovaDomain

// MARK: - Stores

final class WorkspaceStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-ws-\(UUID().uuidString).json")
    }

    func testSeedsDefaultAndPersistsActive() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileWorkspaceStore(url: url)
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Default")
        let active = await store.active()
        XCTAssertEqual(active?.name, "Default")

        let startup = await store.create(name: "Startup", contextNotes: "swift app")
        await store.setActive(id: startup.id)

        // Active selection survives a reload.
        let reloaded = FileWorkspaceStore(url: url)
        let reloadedActive = await reloaded.active()
        XCTAssertEqual(reloadedActive?.id, startup.id)
        XCTAssertEqual(reloadedActive?.contextNotes, "swift app")
    }

    func testDeletingActiveReassigns() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileWorkspaceStore(url: url)
        let extra = await store.create(name: "Extra", contextNotes: "")
        await store.setActive(id: extra.id)
        await store.delete(id: extra.id)

        let active = await store.active()
        XCTAssertNotNil(active)
        XCTAssertNotEqual(active?.id, extra.id)
    }
}

final class SkillStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-skills-\(UUID().uuidString).json")
    }

    func testUpsertUpdatesAndPersists() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileSkillStore(url: url)
        var skill = Skill(name: "Workday", triggerPhrases: ["start my day"], steps: [SkillStep(kind: .say, text: "Good morning")])
        skill = await store.upsert(skill)

        skill.name = "Morning"
        _ = await store.upsert(skill)

        let reloaded = FileSkillStore(url: url)
        let all = await reloaded.all()
        // Store may also contain built-in seeded skills; assert our upsert by id.
        let match = all.first { $0.id == skill.id }
        XCTAssertEqual(match?.name, "Morning")

        await reloaded.delete(id: skill.id)
        let after = await FileSkillStore(url: url).all()
        XCTAssertFalse(after.contains { $0.id == skill.id })
    }
}

final class BookmarkStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-bm-\(UUID().uuidString).json")
    }

    func testSaveListDeletePersists() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileBookmarkStore(url: url)
        _ = await store.save(Bookmark(title: "PostgreSQL", text: "We chose Postgres for JSONB."))
        let saved = await store.save(Bookmark(title: "Swift", text: "Use actors for isolation."))

        let reloaded = FileBookmarkStore(url: url)
        let all = await reloaded.all()
        XCTAssertEqual(all.count, 2)
        // Newest first.
        XCTAssertEqual(all.first?.id, saved.id)

        await reloaded.delete(id: saved.id)
        let after = await FileBookmarkStore(url: url).all()
        XCTAssertEqual(after.count, 1)
    }
}

// MARK: - Knowledge search

final class KnowledgeSearchTests: XCTestCase {
    func testRanksMatchesAcrossSources() async throws {
        let notesURL = FileManager.default.temporaryDirectory.appendingPathComponent("ks-notes-\(UUID().uuidString).json")
        let bmURL = FileManager.default.temporaryDirectory.appendingPathComponent("ks-bm-\(UUID().uuidString).json")
        let factURL = FileManager.default.temporaryDirectory.appendingPathComponent("ks-fact-\(UUID().uuidString).json")
        let memURL = FileManager.default.temporaryDirectory.appendingPathComponent("ks-mem-\(UUID().uuidString).json")
        defer {
            [notesURL, bmURL, factURL, memURL].forEach { try? FileManager.default.removeItem(at: $0) }
        }

        let notes = FileNoteStore(url: notesURL)
        let bookmarks = FileBookmarkStore(url: bmURL)
        let facts = FileFactStore(url: factURL)
        let memory = FileConversationMemory(url: memURL)

        _ = await notes.save("Remember to water the plants")
        _ = await bookmarks.save(Bookmark(title: "Database choice", text: "We decided to use PostgreSQL for the backend."))
        _ = await facts.add("User prefers PostgreSQL over MySQL")
        await memory.append(ConversationTurn(role: .assistant, text: "PostgreSQL supports JSONB indexing."))

        let search = KnowledgeSearch(notes: notes, bookmarks: bookmarks, facts: facts, memory: memory)
        let hits = await search.search("postgresql", limit: 10)

        XCTAssertGreaterThanOrEqual(hits.count, 3)
        XCTAssertTrue(hits.allSatisfy { $0.snippet.lowercased().contains("postgre") || $0.title.lowercased().contains("postgre") || $0.source == .fact })
        // Unrelated note is not returned for this query.
        XCTAssertFalse(hits.contains { $0.snippet.contains("water the plants") })
    }

    func testEmptyQueryReturnsNothing() async {
        let notesURL = FileManager.default.temporaryDirectory.appendingPathComponent("ks-notes2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: notesURL) }
        let notes = FileNoteStore(url: notesURL)
        let bookmarks = FileBookmarkStore(url: notesURL.appendingPathExtension("bm"))
        let facts = FileFactStore(url: notesURL.appendingPathExtension("fact"))
        let memory = FileConversationMemory(url: notesURL.appendingPathExtension("mem"))
        let search = KnowledgeSearch(notes: notes, bookmarks: bookmarks, facts: facts, memory: memory)
        let hits = await search.search("   ", limit: 10)
        XCTAssertTrue(hits.isEmpty)
    }
}

// MARK: - Memory scoping

final class MemoryScopingTests: XCTestCase {
    func testSummaryScopedByWorkspace() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nova-scope-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let wsA = UUID()
        let wsB = UUID()
        let memory = FileConversationMemory(url: url)
        await memory.append(ConversationTurn(role: .user, text: "book flights to Tokyo", workspaceId: wsA))
        await memory.append(ConversationTurn(role: .user, text: "fix the login bug", workspaceId: wsB))

        let a = await memory.summary(workspaceId: wsA)
        XCTAssertTrue(a.contains("Tokyo"))
        XCTAssertFalse(a.contains("login bug"))

        let recentB = await memory.recent(workspaceId: wsB, limit: 10)
        XCTAssertEqual(recentB.count, 1)
        XCTAssertEqual(recentB.first?.text, "fix the login bug")

        // nil workspace = all turns.
        let all = await memory.summary(workspaceId: nil)
        XCTAssertTrue(all.contains("Tokyo"))
        XCTAssertTrue(all.contains("login bug"))
    }
}

// MARK: - Skill runner

final class SkillRunnerTests: XCTestCase {
    func testRunsDeterministicStepsAndCollectsFreeform() async throws {
        let notesURL = FileManager.default.temporaryDirectory.appendingPathComponent("sr-notes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: notesURL) }
        let notes = FileNoteStore(url: notesURL)

        let opened = OpenedBox()
        let runner = SkillRunner(
            notes: notes,
            openURL: { url in await opened.set(url.absoluteString); return true },
            startTimer: { _, _ in true }
        )

        let skill = Skill(
            name: "Focus",
            triggerPhrases: ["focus time"],
            steps: [
                SkillStep(kind: .note, text: "Deep work block"),
                SkillStep(kind: .openURL, url: "https://example.com"),
                SkillStep(kind: .timer, text: "Pomodoro", seconds: 1500),
                SkillStep(kind: .say, text: "Focus mode on"),
                SkillStep(kind: .freeform, text: "play focus playlist")
            ]
        )

        let result = await runner.run(skill)
        XCTAssertTrue(result.summaryLines.contains("saved a note"))
        XCTAssertTrue(result.summaryLines.contains { $0.contains("example.com") })
        XCTAssertTrue(result.summaryLines.contains { $0.contains("timer") })
        XCTAssertEqual(result.sayLines, ["Focus mode on"])
        XCTAssertEqual(result.freeform, ["play focus playlist"])
        let openedURL = await opened.value
        XCTAssertEqual(openedURL, "https://example.com")

        let savedNotes = await notes.all()
        XCTAssertEqual(savedNotes.first?.text, "Deep work block")
    }
}

private actor OpenedBox {
    private(set) var value: String?
    func set(_ v: String) { value = v }
}

// MARK: - Follow-up suggestion parsing

final class FollowUpSuggesterParsingTests: XCTestCase {
    func testParsesJSONArray() {
        let out = FollowUpSuggester.parseSuggestions(#"["Tell me more","Give an example","Summarize it"]"#)
        XCTAssertEqual(out, ["Tell me more", "Give an example", "Summarize it"])
    }

    func testParsesFencedJSON() {
        let text = "```json\n[\"One\", \"Two\"]\n```"
        XCTAssertEqual(FollowUpSuggester.parseSuggestions(text), ["One", "Two"])
    }

    func testFallsBackToLineSplitting() {
        let text = "- First idea\n- Second idea"
        XCTAssertEqual(FollowUpSuggester.parseSuggestions(text), ["First idea", "Second idea"])
    }

    func testCapsAtThree() {
        let out = FollowUpSuggester.parseSuggestions(#"["a","b","c","d","e"]"#)
        XCTAssertEqual(out.count, 3)
    }
}
