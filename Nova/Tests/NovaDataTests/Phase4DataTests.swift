import XCTest
@testable import NovaCore
@testable import NovaData
@testable import NovaDomain

// MARK: - Skill runner: webhook + delay steps (P4.4)

final class SkillRunnerWebhookDelayTests: XCTestCase {
    func testWebhookStepIssuesRequestWithMethodAndBody() async {
        let notesURL = FileManager.default.temporaryDirectory.appendingPathComponent("p4-notes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: notesURL) }
        let notes = FileNoteStore(url: notesURL)

        let captured = RequestBox()
        let runner = SkillRunner(
            notes: notes,
            callWebhook: { request in
                await captured.set(request)
                return true
            }
        )

        let skill = Skill(name: "Ping", steps: [
            SkillStep(kind: .webhook, text: #"{"on":true}"#, url: "https://example.com/hook", httpMethod: "POST")
        ])
        let result = await runner.run(skill)
        XCTAssertTrue(result.summaryLines.contains("called the webhook"))

        let req = await captured.value
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.url?.absoluteString, "https://example.com/hook")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req?.httpBody, Data(#"{"on":true}"#.utf8))
    }

    func testWebhookFailureIsReported() async {
        let notes = FileNoteStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("p4-notes2-\(UUID().uuidString).json"))
        let runner = SkillRunner(notes: notes, callWebhook: { _ in false })
        let skill = Skill(name: "Ping", steps: [SkillStep(kind: .webhook, url: "https://example.com")])
        let result = await runner.run(skill)
        XCTAssertTrue(result.summaryLines.contains("couldn't reach the webhook"))
    }

    func testDelayStepWaitsRequestedSecondsCapped() async {
        let notes = FileNoteStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("p4-notes3-\(UUID().uuidString).json"))
        let slept = SecondsBox()
        let runner = SkillRunner(
            notes: notes,
            sleep: { seconds in await slept.set(seconds) }
        )
        // Over the cap → clamped to maxDelaySeconds.
        let skill = Skill(name: "Wait", steps: [SkillStep(kind: .delay, seconds: 100_000)])
        let result = await runner.run(skill)
        let waited = await slept.value
        XCTAssertEqual(waited, TimeInterval(SkillRunner.maxDelaySeconds))
        XCTAssertTrue(result.summaryLines.contains { $0.contains("waited") })
    }

    func testVariableInterpolationAndConditionSkip() async {
        let notesURL = FileManager.default.temporaryDirectory.appendingPathComponent("p4-notes-var-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: notesURL) }
        let notes = FileNoteStore(url: notesURL)
        let attempts = CounterBox()
        let runner = SkillRunner(
            notes: notes,
            callWebhook: { _ in
                await attempts.inc()
                return true
            },
            sleep: { _ in }
        )
        let skill = Skill(name: "Vars", steps: [
            SkillStep(kind: .say, text: "hi", outputVariable: "greet"),
            SkillStep(
                kind: .note,
                text: "Said {{greet}}"
            ),
            SkillStep(
                kind: .webhook,
                url: "https://example.com/skip",
                condition: SkillCondition(variable: "greet", equals: "nope")
            ),
            SkillStep(
                kind: .webhook,
                url: "https://example.com/ok",
                retryPolicy: SkillRetryPolicy(maxAttempts: 2, delaySeconds: 0)
            )
        ])
        let result = await runner.run(skill)
        XCTAssertTrue(result.summaryLines.contains("saved a note"))
        XCTAssertTrue(result.summaryLines.contains { $0.contains("skipped") })
        XCTAssertEqual(await attempts.value, 1)
        let saved = await notes.all()
        XCTAssertTrue(saved.contains { $0.text.contains("Said hi") })
    }

    func testConfirmationDenialSkipsStep() async {
        let notes = FileNoteStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("p4-notes-conf-\(UUID().uuidString).json"))
        let runner = SkillRunner(
            notes: notes,
            callWebhook: { _ in true },
            confirm: { _, _ in false }
        )
        let skill = Skill(name: "Confirm", steps: [
            SkillStep(kind: .webhook, url: "https://example.com", requiresConfirmation: true)
        ])
        let result = await runner.run(skill)
        XCTAssertTrue(result.summaryLines.contains { $0.contains("denied") })
    }
}

private actor CounterBox {
    private(set) var value = 0
    func inc() { value += 1 }
}

private actor RequestBox {
    private(set) var value: URLRequest?
    func set(_ v: URLRequest) { value = v }
}

private actor SecondsBox {
    private(set) var value: TimeInterval?
    func set(_ v: TimeInterval) { value = v }
}

// MARK: - Draft message tool (P4.3)

final class DraftMessageToolTests: XCTestCase {
    private func tool(opened: URLBox? = nil) -> DraftMessageTool {
        let notes = FileNoteStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("p4-dm-\(UUID().uuidString).json"))
        return DraftMessageTool(notes: notes, openURL: { url in
            if let opened { await opened.set(url) }
            return true
        })
    }

    func testEmailOpensMailtoComposer() async throws {
        let opened = URLBox()
        let json = #"{"type":"email","to":"a@b.com","subject":"Hi there","body":"Let's meet"}"#
        let out = try await tool(opened: opened).invoke(argumentsJSON: json)
        XCTAssertTrue(out.contains(#""drafted":"email""#))
        let url = await opened.value?.absoluteString ?? ""
        XCTAssertTrue(url.hasPrefix("mailto:a@b.com?"))
        XCTAssertTrue(url.contains("subject=Hi%20there"))
    }

    func testEventRequiresStartTime() async throws {
        let json = #"{"type":"event","body":"Team sync"}"#
        let out = try await tool().invoke(argumentsJSON: json)
        XCTAssertTrue(out.contains("missing_start_time"))
    }

    func testNoteIsSavedToStore() async throws {
        let notesURL = FileManager.default.temporaryDirectory.appendingPathComponent("p4-dm-note-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: notesURL) }
        let notes = FileNoteStore(url: notesURL)
        let tool = DraftMessageTool(notes: notes)
        let out = try await tool.invoke(argumentsJSON: #"{"type":"note","body":"remember the milk"}"#)
        XCTAssertTrue(out.contains(#""drafted":"note""#))
        let all = await notes.all()
        XCTAssertEqual(all.first?.text, "remember the milk")
    }
}

private actor URLBox {
    private(set) var value: URL?
    func set(_ v: URL) { value = v }
}

// MARK: - Home Assistant state tool (P4.2)

final class HomeAssistantStateToolTests: XCTestCase {
    func testSummarizeExtractsStateNameAndUnit() {
        let json = #"""
        {"entity_id":"sensor.living_room","state":"71.5","attributes":{"friendly_name":"Living Room","unit_of_measurement":"°F"},"last_changed":"2026-07-17T10:00:00Z"}
        """#
        let out = HomeAssistantStateTool.summarize(data: Data(json.utf8), entityId: "sensor.living_room")
        XCTAssertTrue(out.contains(#""ok":true"#))
        XCTAssertTrue(out.contains(#""state":"71.5""#))
        XCTAssertTrue(out.contains("Living Room"))
        XCTAssertTrue(out.contains("°F") || out.contains("\\u00b0F"))
    }

    func testSummarizeHandlesMalformedPayload() {
        let out = HomeAssistantStateTool.summarize(data: Data("not json".utf8), entityId: "sensor.x")
        XCTAssertTrue(out.contains(#""ok":false"#))
        XCTAssertTrue(out.contains("bad_response"))
    }

    func testUnconfiguredThrows() async {
        let tool = HomeAssistantStateTool(baseURL: nil, token: nil)
        do {
            _ = try await tool.invoke(argumentsJSON: #"{"entityId":"sensor.x"}"#)
            XCTFail("expected an error when unconfigured")
        } catch {
            // expected
        }
    }
}
