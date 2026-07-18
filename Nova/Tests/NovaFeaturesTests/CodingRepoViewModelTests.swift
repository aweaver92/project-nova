import XCTest
@testable import NovaDomain
@testable import NovaFeatures

@MainActor
final class CodingRepoViewModelTests: XCTestCase {
    func testPublishConfirmationDenialDoesNotCallBridge() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        vm.confirmPublish = { _, _ in false }

        await vm.load()
        await vm.refreshRepoStatusAndDiff()
        XCTAssertEqual(vm.repoStatus?.clean, false)

        await vm.publishPullRequest()
        XCTAssertEqual(vm.statusMessage, "Publish cancelled.")
        let calls = await bridge.publishCallCount
        XCTAssertEqual(calls, 0)
    }

    func testSelectRepositoryClearsPinnedSession() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "1111111111111111", sessionId: "stale")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        await vm.load()
        XCTAssertEqual(vm.pinnedSessionId, "stale")

        await vm.selectRepository("abcdef0123456789")
        XCTAssertNil(vm.pinnedSessionId)
        XCTAssertEqual(vm.selectedRepoId, "abcdef0123456789")
        let sessionAfter = await settings.codingSessionId()
        XCTAssertNil(sessionAfter)
    }
}

private actor MemorySettings: SettingsStoring {
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

private actor DirtyRepoBridge: AgentBridging {
    private(set) var publishCallCount = 0

    func isConfigured() async -> Bool { true }

    func listRepos() async -> BridgeResult {
        BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"selectedRepoId":"abcdef0123456789","repos":[{"id":"abcdef0123456789","name":"demo","relativePath":"demo","rootLabel":"src","selected":true},{"id":"1111111111111111","name":"other","relativePath":"other","rootLabel":"src","selected":false}]}"#
        )
    }

    func selectRepository(repoId: String) async -> BridgeResult {
        BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"selectedRepoId":"\#(repoId)","repo":{"id":"\#(repoId)","name":"demo","relativePath":"demo","rootLabel":"src","selected":true}}"#
        )
    }

    func repositoryStatus(repoId: String) async -> BridgeResult {
        BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"status":{"repoId":"\#(repoId)","name":"demo","branch":"main","upstream":"origin/main","ahead":0,"behind":0,"clean":false,"changedFiles":[{"path":"a.swift","status":"M","staged":false,"unstaged":true}],"statusToken":"tok1234567890123456789012"}}"#
        )
    }

    func repositoryDiff(repoId: String) async -> BridgeResult {
        BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"repoId":"\#(repoId)","diff":"diff --git a/a.swift","truncated":false,"statusToken":"tok1234567890123456789012"}"#
        )
    }

    func publishRepository(repoId: String, request: BridgePublishRequest) async -> BridgeResult {
        publishCallCount += 1
        return BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"repoId":"\#(repoId)","branch":"nova/x","commitSha":"abc","prUrl":"https://github.com/acme/demo/pull/1","prNumber":1}"#
        )
    }

    func listCursorSessions() async -> BridgeResult {
        BridgeResult(ok: true, payloadJSON: #"{"ok":true,"sessions":[]}"#)
    }

    func fetchCursorSessionMessages(sessionId: String) async -> BridgeResult {
        BridgeResult(ok: true, payloadJSON: #"{"ok":true,"messages":[]}"#)
    }
}
