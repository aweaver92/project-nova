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
        XCTAssertTrue(max.personality.contains("Training screen"))
        XCTAssertTrue(remy.toolNames!.contains("list_pantry"))
        XCTAssertTrue(remy.toolNames!.contains("remember_visual"))
        XCTAssertTrue(remy.toolNames!.contains("scan_fridge"))
        XCTAssertTrue(remy.toolNames!.contains("start_cooking"))
        XCTAssertTrue(remy.toolNames!.contains("get_nutrition_profile"))
        XCTAssertTrue(remy.toolNames!.contains("open_app_screen"))
        XCTAssertTrue(sage.toolNames!.contains("list_tasks"))
        XCTAssertTrue(sage.toolNames!.contains("create_task"))
        XCTAssertTrue(sage.toolNames!.contains("update_task"))
        XCTAssertTrue(sage.toolNames!.contains("agent_activity"))
        XCTAssertTrue(sage.toolNames!.contains("switch_agent"))
        XCTAssertTrue(sage.toolNames!.contains("daily_briefing"))
        XCTAssertTrue(sage.toolNames!.contains("open_app_screen"))
        XCTAssertTrue(sage.personality.contains("task manager") || sage.role.contains("task manager"))
        XCTAssertFalse(sage.toolNames!.contains("log_wellness_checkin"))
        XCTAssertTrue(scholar.toolNames!.contains("start_quiz"))
        XCTAssertTrue(scholar.toolNames!.contains("reveal_card"))
        XCTAssertTrue(scholar.toolNames!.contains("list_study_cards"))
        XCTAssertTrue(scholar.toolNames!.contains("update_study_card"))
        XCTAssertTrue(scholar.toolNames!.contains("delete_study_card"))
        XCTAssertTrue(scholar.toolNames!.contains("open_app_screen"))
        XCTAssertTrue(claude.toolNames!.contains("push_to_cursor"))
        XCTAssertTrue(claude.toolNames!.contains("get_cursor_session_history"))
        XCTAssertTrue(claude.toolNames!.contains("list_repos"))
        XCTAssertTrue(claude.toolNames!.contains("create_web_project"))
        XCTAssertTrue(claude.toolNames!.contains("publish_repo"))
        XCTAssertTrue(claude.toolNames!.contains("draft_message"))
        XCTAssertTrue(claude.toolNames!.contains("open_app_screen"))
        XCTAssertTrue(max.toolNames!.contains("open_app_screen"))

        // Specialists share OpenAI's recommended Realtime voices (marin/cedar).
        // Legacy ash/sage/ballad/verse sound quieter and less clear than Nova.
        for agent in [nova, claude, max, sage, remy, scholar] {
            let voice = RealtimeVoice(rawValue: agent.voice)
            XCTAssertNotNil(voice, agent.name)
            XCTAssertTrue(voice!.isRecommendedQuality, "\(agent.name) voice \(agent.voice)")
        }
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
        XCTAssertEqual(active?.planId, saved.id)
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

    func testTaskCreateListAndUpdate() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileTaskStore(url: url)
        let create = CreateTaskTool(store: store, agentsProvider: { Agent.builtInAgents() })
        let created = try await create.invoke(argumentsJSON: #"{"title":"Finish PR review","agent":"Claude","status":"incomplete","source":"inferred","activity_summary":"Left mid-review"}"#)
        XCTAssertTrue(created.contains("ok\":true"))

        let list = ListTasksTool(store: store)
        let listed = try await list.invoke(argumentsJSON: #"{"limit":5}"#)
        XCTAssertTrue(listed.contains("Finish PR review"))
        XCTAssertTrue(listed.contains("incomplete"))

        let open = await store.open(limit: 10)
        XCTAssertEqual(open.count, 1)
        let id = open[0].id.uuidString
        let update = UpdateTaskTool(store: store)
        let updated = try await update.invoke(argumentsJSON: #"{"id":"\#(id)","status":"done"}"#)
        XCTAssertTrue(updated.contains("done"))
        let remaining = await store.open(limit: 10)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAgentActivitySummarizesSpecialistMemory() async throws {
        let memURL = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: memURL) }
        let memory = FileConversationMemory(url: memURL)
        let maxId = Agent.SeedID.max
        await memory.append(ConversationTurn(role: .user, text: "start push day", workspaceId: maxId))
        await memory.append(ConversationTurn(role: .assistant, text: "logged bench press", workspaceId: maxId))
        let tool = AgentActivityTool(memory: memory, agentsProvider: { Agent.builtInAgents() })
        let json = try await tool.invoke(argumentsJSON: #"{"agent":"Max","limit":5}"#)
        XCTAssertTrue(json.contains("\"ok\":true"))
        XCTAssertTrue(json.contains("push day") || json.contains("bench"))
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

    func testDueFiltersByDeckBeforeLimit() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("study-due-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileStudyDeckStore(url: url)
        for i in 0..<12 {
            _ = await store.upsert(StudyCard(deck: "A", front: "A\(i)", back: "a"))
        }
        let target = await store.upsert(StudyCard(deck: "B", front: "Only B", back: "b"))
        let dueB = await store.due(deck: "B", limit: 5)
        XCTAssertEqual(dueB.count, 1)
        XCTAssertEqual(dueB.first?.id, target.id)

        let quiz = StartQuizTool(store: store)
        let quizJSON = try! await quiz.invoke(argumentsJSON: #"{"deck":"B","limit":5}"#)
        XCTAssertTrue(quizJSON.contains("\"count\":1"))
        XCTAssertTrue(quizJSON.contains("Only B"))
        XCTAssertFalse(quizJSON.contains("\"back\""))
    }

    func testRevealThenGradeFlow() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("study-reveal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileStudyDeckStore(url: url)
        let card = await store.upsert(StudyCard(deck: "Hist", front: "Year?", back: "1776"))

        let reveal = RevealCardTool(store: store)
        let revealed = try await reveal.invoke(argumentsJSON: #"{"id":"\#(card.id.uuidString)"}"#)
        XCTAssertTrue(revealed.contains("\"back\":\"1776\""))

        let grade = GradeCardTool(store: store)
        let graded = try await grade.invoke(
            argumentsJSON: #"{"id":"\#(card.id.uuidString)","grade":"good","user_answer":"1776"}"#
        )
        XCTAssertTrue(graded.contains("\"ok\":true"))
        XCTAssertTrue(graded.contains("\"user_answer\":\"1776\""))
        let gradedCard = await store.card(id: card.id)
        XCTAssertGreaterThan(gradedCard!.dueAt, Date())
    }

    func testUpdateAndDeleteStudyCardTools() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("study-crud-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileStudyDeckStore(url: url)
        let card = await store.upsert(StudyCard(deck: "Old", front: "Q", back: "A"))

        let update = UpdateStudyCardTool(store: store)
        let updated = try await update.invoke(
            argumentsJSON: #"{"id":"\#(card.id.uuidString)","deck":"New","front":"Q2","back":"A2"}"#
        )
        XCTAssertTrue(updated.contains("\"ok\":true"))
        let listed = try await ListStudyCardsTool(store: store).invoke(argumentsJSON: #"{"deck":"New"}"#)
        XCTAssertTrue(listed.contains("Q2"))
        XCTAssertTrue(listed.contains("A2"))

        let del = DeleteStudyCardTool(store: store)
        let deleted = try await del.invoke(argumentsJSON: #"{"id":"\#(card.id.uuidString)"}"#)
        XCTAssertTrue(deleted.contains("\"ok\":true"))
        let remaining = await store.card(id: card.id)
        XCTAssertNil(remaining)
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
        XCTAssertTrue(all.contains { $0.name == "Sage pickup review" })
    }
}
