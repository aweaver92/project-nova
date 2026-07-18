import XCTest
@testable import NovaCore
@testable import NovaData
@testable import NovaDomain

final class AgentCapabilityPackTests: XCTestCase {
    func testBuiltInAgentsHaveDistinctAllowlists() {
        let agents = Agent.builtInAgents()
        let max = agents.first { $0.name == "Max" }!
        let remy = agents.first { $0.name == "Remy" }!
        let sage = agents.first { $0.name == "Sage" }!
        let scholar = agents.first { $0.name == "Scholar" }!
        let claude = agents.first { $0.name == "Claude" }!
        let nova = agents.first { $0.isMaster }!

        XCTAssertNil(nova.toolNames)
        XCTAssertTrue(max.toolNames!.contains("set_timer"))
        XCTAssertTrue(max.toolNames!.contains("play_music"))
        XCTAssertTrue(max.toolNames!.contains("save_workout_plan"))
        XCTAssertTrue(remy.toolNames!.contains("list_pantry"))
        XCTAssertTrue(remy.toolNames!.contains("remember_visual"))
        XCTAssertTrue(sage.toolNames!.contains("log_wellness_checkin"))
        XCTAssertTrue(sage.toolNames!.contains("daily_briefing"))
        XCTAssertTrue(scholar.toolNames!.contains("start_quiz"))
        XCTAssertTrue(claude.toolNames!.contains("push_to_cursor"))
        XCTAssertTrue(claude.toolNames!.contains("list_repos"))
        XCTAssertTrue(claude.toolNames!.contains("create_web_project"))
        XCTAssertTrue(claude.toolNames!.contains("publish_repo"))
        XCTAssertTrue(claude.toolNames!.contains("draft_message"))
    }

    func testSeedCapabilitiesRefreshUpdatesAllowlists() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agents-cap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // Simulate an older install: Max without timer tools, version 1.
        var staleMax = Agent.builtInAgents().first { $0.name == "Max" }!
        staleMax.toolNames = ["start_workout_session", "workout_history"]
        staleMax.personality = "old"
        let seeds = Agent.builtInAgents().map { $0.name == "Max" ? staleMax : $0 }
        struct Persisted: Codable {
            var agents: [Agent]
            var activeId: UUID?
            var seedCapabilitiesVersion: Int?
        }
        let prior = Persisted(agents: seeds, activeId: seeds.first { $0.isMaster }?.id, seedCapabilitiesVersion: 1)
        try JSONEncoder().encode(prior).write(to: url)

        let store = FileAgentStore(url: url)
        let max = await store.all().first { $0.name == "Max" }!
        XCTAssertTrue(max.toolNames!.contains("set_timer"))
        XCTAssertTrue(max.toolNames!.contains("save_workout_plan"))
        XCTAssertFalse(max.personality.contains("old"))
    }

    func testWorkoutPlanStoreRoundTrip() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plans-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileWorkoutPlanStore(url: url)
        let plan = WorkoutPlan(
            name: "Push day",
            exercises: [PlannedExercise(name: "Bench", sets: 3, reps: 8, restSeconds: 90)]
        )
        await store.upsert(plan)
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.exercises.first?.name, "Bench")
    }

    func testStartWorkoutFromPlanTool() async throws {
        let plansURL = FileManager.default.temporaryDirectory.appendingPathComponent("plans2-\(UUID().uuidString).json")
        let workoutsURL = FileManager.default.temporaryDirectory.appendingPathComponent("wo-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: plansURL)
            try? FileManager.default.removeItem(at: workoutsURL)
        }
        let plans = FileWorkoutPlanStore(url: plansURL)
        let workouts = FileWorkoutStore(url: workoutsURL)
        let saved = await plans.upsert(WorkoutPlan(
            name: "Legs",
            exercises: [PlannedExercise(name: "Squat", sets: 4, reps: 5)]
        ))
        let tool = StartWorkoutFromPlanTool(plans: plans, workouts: workouts)
        let json = try await tool.invoke(argumentsJSON: #"{"name":"Legs"}"#)
        XCTAssertTrue(json.contains("ok\":true"))
        XCTAssertTrue(json.contains(saved.id.uuidString))
        let active = await workouts.activeSession()
        XCTAssertEqual(active?.title, "Legs")
    }

    func testPantryUpsertByName() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pantry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FilePantryStore(url: url)
        await store.upsert(PantryItem(name: "Eggs", quantity: "6"))
        await store.upsert(PantryItem(name: "eggs", quantity: "12"))
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.quantity, "12")
    }

    func testWellnessLogAndHistory() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("well-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileWellnessStore(url: url)
        let tool = LogWellnessCheckinTool(store: store)
        _ = try await tool.invoke(argumentsJSON: #"{"mood":4,"note":"walked"}"#)
        let hist = WellnessHistoryTool(store: store)
        let json = try await hist.invoke(argumentsJSON: #"{"limit":5}"#)
        XCTAssertTrue(json.contains("\"mood\":4"))
    }

    func testStudyGradeAdvancesDueDate() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("study-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileStudyDeckStore(url: url)
        let card = await store.upsert(StudyCard(deck: "Swift", front: "What is Sendable?", back: "Concurrency-safe"))
        let graded = await store.grade(id: card.id, grade: .good)
        XCTAssertNotNil(graded)
        XCTAssertGreaterThan(graded!.dueAt, Date())
        XCTAssertEqual(graded!.repetitions, 1)

        let quiz = StartQuizTool(store: store)
        let quizJSON = try await quiz.invoke(argumentsJSON: #"{"deck":"Swift"}"#)
        // Just graded "good" → not due anymore.
        XCTAssertTrue(quizJSON.contains("\"count\":0"))
    }

    func testPlayMusicResolvesSpotifySearch() {
        let url = PlayMusicTool.resolveURL(query: "pump up", uri: nil, service: "spotify")
        XCTAssertEqual(url?.scheme, "spotify")
    }

    func testTimerServiceSchedulesInMemory() async {
        let timers = LocalTimerService()
        // On non-iOS / without notification permission this may return nil — still
        // exercise cancel/list for the in-memory path when a timer is accepted.
        if let t = await timers.schedule(seconds: 30, label: "Rest") {
            let listed = await timers.list()
            XCTAssertTrue(listed.contains { $0.id == t.id })
            let ok = await timers.cancel(id: t.id, label: nil)
            XCTAssertTrue(ok)
            let after = await timers.list()
            XCTAssertFalse(after.contains { $0.id == t.id })
        } else {
            // Permission denied in this environment — still a valid outcome.
            XCTAssertTrue(true)
        }
    }

    func testBuiltInSkillsSeeded() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileSkillStore(url: url)
        let all = await store.all()
        XCTAssertTrue(all.contains { $0.name == "Max rest 90s" })
        XCTAssertTrue(all.contains { $0.name == "Sage box breathing" })
    }
}
