import XCTest
@testable import NovaData
@testable import NovaDomain

final class RepoWorkflowTests: XCTestCase {
    func testSelectRepoClearsPinnedCursorSession() async throws {
        let settings = InMemoryRepoSettings(repoId: nil, sessionId: "old-session")
        let bridge = RecordingRepoBridge()
        let tool = SelectRepoTool(bridge: bridge, settings: settings)
        let payload = try await tool.invoke(argumentsJSON: #"{"repo_id":"abcdef0123456789"}"#)
        XCTAssertTrue(payload.contains("abcdef0123456789"))
        let session = await settings.codingSessionId()
        let selected = await settings.codingSelectedRepoId()
        XCTAssertNil(session)
        XCTAssertEqual(selected, "abcdef0123456789")
    }

    func testPublishRepoRequiresSelectedRepo() async throws {
        let settings = InMemoryRepoSettings(repoId: nil)
        let bridge = RecordingRepoBridge()
        let tool = PublishRepoTool(bridge: bridge, settings: settings)
        let payload = try await tool.invoke(argumentsJSON: """
        {"status_token":"tok","commit_message":"x","pr_title":"y"}
        """)
        XCTAssertTrue(payload.contains("no_repo_selected"))
        let calls = await bridge.publishCallCount
        XCTAssertEqual(calls, 0)
    }

    func testPublishRepoForwardsRequest() async throws {
        let settings = InMemoryRepoSettings(repoId: "abcdef0123456789")
        let bridge = RecordingRepoBridge()
        let tool = PublishRepoTool(bridge: bridge, settings: settings)
        let payload = try await tool.invoke(argumentsJSON: """
        {"status_token":"tok1234567890123456789012","commit_message":"ship it","pr_title":"Ship it","branch_name":"fix-login"}
        """)
        XCTAssertTrue(payload.contains("pull/1"))
        let request = await bridge.lastPublishRequest
        XCTAssertEqual(request?.commitMessage, "ship it")
        XCTAssertEqual(request?.prTitle, "Ship it")
        XCTAssertEqual(request?.branchName, "fix-login")
        XCTAssertEqual(request?.statusToken, "tok1234567890123456789012")
    }

    func testRunClaudeCodeSendsRepoIdNotCwd() async throws {
        let settings = InMemoryRepoSettings(repoId: "abcdef0123456789")
        let bridge = RecordingRepoBridge()
        let tool = RunClaudeCodeTool(bridge: bridge, settings: settings)
        _ = try await tool.invoke(argumentsJSON: #"{"prompt":"refactor"}"#)
        let repoId = await bridge.lastClaudeRepoId
        XCTAssertEqual(repoId, "abcdef0123456789")
    }

    func testCreateWebProjectSelectsRepoAndClearsSession() async throws {
        let settings = InMemoryRepoSettings(repoId: nil, sessionId: "old-session")
        let bridge = RecordingRepoBridge()
        let tool = CreateWebProjectTool(bridge: bridge, settings: settings)
        let payload = try await tool.invoke(argumentsJSON: """
        {"name":"portfolio-site","description":"A design portfolio","template":"react-vite"}
        """)
        XCTAssertTrue(payload.contains("https://github.com/acme/portfolio-site"))
        let selected = await settings.codingSelectedRepoId()
        let session = await settings.codingSessionId()
        XCTAssertEqual(selected, "abcdef0123456789")
        XCTAssertNil(session)
        let request = await bridge.lastCreateRequest
        XCTAssertEqual(request?.name, "portfolio-site")
        XCTAssertEqual(request?.template, .reactVite)
    }
}

private actor InMemoryRepoSettings: SettingsStoring {
    private var repoId: String?
    private var sessionId: String?

    init(repoId: String?, sessionId: String? = nil) {
        self.repoId = repoId
        self.sessionId = sessionId
    }

    func spokenFollowUps() async -> Bool { false }
    func setSpokenFollowUps(_ enabled: Bool) async {}
    func codingSessionId() async -> String? { sessionId }
    func setCodingSessionId(_ value: String?) async {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionId = (trimmed?.isEmpty == false) ? trimmed : nil
    }
    func codingSelectedRepoId() async -> String? { repoId }
    func setCodingSelectedRepoId(_ value: String?) async {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        repoId = (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

private actor RecordingRepoBridge: AgentBridging {
    private(set) var publishCallCount = 0
    private(set) var lastPublishRequest: BridgePublishRequest?
    private(set) var lastClaudeRepoId: String?
    private(set) var lastCreateRequest: BridgeCreateProjectRequest?

    func isConfigured() async -> Bool { true }

    func runClaudeCode(prompt: String, workingDirectory: String?, repoId: String?) async -> BridgeResult {
        lastClaudeRepoId = repoId
        return BridgeResult(ok: true, payloadJSON: #"{"ok":true,"result":"done"}"#)
    }

    func selectRepository(repoId: String) async -> BridgeResult {
        BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"selectedRepoId":"\#(repoId)","repo":{"id":"\#(repoId)","name":"demo","relativePath":"demo","rootLabel":"src","selected":true}}"#
        )
    }

    func createPublicWebProject(request: BridgeCreateProjectRequest) async -> BridgeResult {
        lastCreateRequest = request
        return BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"repo":{"id":"abcdef0123456789","name":"portfolio-site","relativePath":"portfolio-site","rootLabel":"src","selected":true},"repoUrl":"https://github.com/acme/portfolio-site","template":"react-vite","selectedRepoId":"abcdef0123456789"}"#
        )
    }

    func publishRepository(repoId: String, request: BridgePublishRequest) async -> BridgeResult {
        publishCallCount += 1
        lastPublishRequest = request
        return BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"repoId":"\#(repoId)","branch":"nova/x","commitSha":"abc","prUrl":"https://github.com/acme/demo/pull/1","prNumber":1}"#
        )
    }
}
