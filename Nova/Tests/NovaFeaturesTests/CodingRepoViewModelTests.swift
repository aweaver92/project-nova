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

    func testSelectRepositoryDoesNotReuseAnotherReposPinnedSession() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "1111111111111111", sessionId: "stale")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        await vm.load()
        // Code view sessions start fresh — persisted pins are not auto-restored.
        XCTAssertNil(vm.pinnedSessionId)

        await vm.beginCodeViewSession()
        await vm.attach(sessionId: "stale")
        XCTAssertEqual(vm.pinnedSessionId, "stale")

        await vm.selectRepository("abcdef0123456789")
        XCTAssertNil(vm.pinnedSessionId)
        XCTAssertEqual(vm.selectedRepoId, "abcdef0123456789")
        let sessionAfter = await settings.codingSessionId()
        XCTAssertNil(sessionAfter)
    }

    func testBeginCodeViewSessionClearsPriorPin() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "abcdef0123456789", sessionId: "old-agent")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        await vm.load()
        await vm.beginCodeViewSession()
        XCTAssertNil(vm.pinnedSessionId)
        let cleared = await settings.codingSessionId()
        XCTAssertNil(cleared)
        XCTAssertTrue(vm.items.isEmpty)
    }

    func testReenteringCodeViewPreservesActiveSessionAndRun() async {
        let bridge = DirtyRepoBridge(streamDelaySeconds: 0.25)
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        await vm.load()
        await vm.beginCodeViewSession()

        vm.draft = "long job"
        let sendTask = Task { await vm.send() }
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(vm.isRunning)
        XCTAssertTrue(vm.isCodeViewSessionActive)
        let itemsBefore = vm.items.count

        // Simulate leaving Coding and coming back (NavigationLink pop/push).
        await vm.beginCodeViewSession()
        XCTAssertTrue(vm.isCodeViewSessionActive)
        XCTAssertTrue(vm.isRunning)
        XCTAssertEqual(vm.items.count, itemsBefore)

        await sendTask.value
        XCTAssertFalse(vm.isRunning)
        XCTAssertEqual(vm.pinnedSessionId, "agent-test")
        let commands = await bridge.receivedCommands
        XCTAssertEqual(commands, ["long job"])
    }

    func testMultiplePromptsReuseTheSameSession() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        await vm.load()
        await vm.beginCodeViewSession()

        vm.draft = "first prompt"
        await vm.send()
        XCTAssertEqual(vm.pinnedSessionId, "agent-test")

        vm.draft = "follow-up in same chat"
        await vm.send()
        XCTAssertEqual(vm.pinnedSessionId, "agent-test")
        let commands = await bridge.receivedCommands
        let sessionIds = await bridge.receivedSessionIds
        XCTAssertEqual(commands, ["first prompt", "follow-up in same chat"])
        XCTAssertEqual(sessionIds.count, 2)
        XCTAssertNil(sessionIds[0])
        XCTAssertEqual(sessionIds[1], "agent-test")
    }

    func testPromptSubmittedDuringActiveRunQueuesAndUsesSameSession() async {
        let bridge = DirtyRepoBridge(streamDelaySeconds: 0.2)
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        await vm.load()
        await vm.beginCodeViewSession()

        vm.draft = "first prompt"
        let firstSend = Task { await vm.send() }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(vm.isRunning)

        vm.draft = "queued follow-up"
        await vm.send()

        XCTAssertEqual(vm.queuedPromptCount, 1)
        XCTAssertTrue(vm.draft.isEmpty)
        await firstSend.value

        let commands = await bridge.receivedCommands
        let sessionIds = await bridge.receivedSessionIds
        XCTAssertEqual(commands, ["first prompt", "queued follow-up"])
        XCTAssertEqual(sessionIds, [nil, "agent-test"])
        XCTAssertEqual(vm.queuedPromptCount, 0)
        XCTAssertFalse(vm.isRunning)
    }

    func testEndSessionRequiresCodeViewToReopenBeforeNextChat() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        await vm.load()
        await vm.beginCodeViewSession()
        vm.draft = "open chat"
        await vm.send()
        XCTAssertEqual(vm.pinnedSessionId, "agent-test")

        await vm.endSession()
        XCTAssertNil(vm.pinnedSessionId)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertFalse(vm.isCodeViewSessionActive)

        vm.draft = "must not start silently"
        await vm.send()
        let commands = await bridge.receivedCommands
        XCTAssertEqual(commands, ["open chat"])
    }

    func testImageOnlyPromptSendsAttachmentAndClearsComposer() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        await vm.beginCodeViewSession()
        vm.addImage(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png",
            width: 1,
            height: 1
        )

        await vm.send()

        let imageCount = await bridge.receivedImageCount
        XCTAssertEqual(imageCount, 1)
        XCTAssertTrue(vm.pendingImages.isEmpty)
        XCTAssertTrue(vm.items.first?.text.contains("Analyze the attached image") == true)
        XCTAssertTrue(vm.items.first?.text.contains("📎 1 image") == true)
    }

    func testRetryLastResendsPreviousCommand() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings)

        XCTAssertFalse(vm.canRetry)
        await vm.beginCodeViewSession()
        vm.draft = "fix the build"
        await vm.send()
        XCTAssertTrue(vm.canRetry)

        await vm.retryLast()

        let commands = await bridge.receivedCommands
        XCTAssertEqual(commands, ["fix the build", "fix the build"])
        let userRows = vm.items.filter { $0.kind == .user }
        XCTAssertEqual(userRows.count, 2)
    }

    func testBrowsesFoldersAndStartsSelectedFilePreview() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        await vm.load()

        await vm.browseRepository()
        XCTAssertEqual(vm.repoFileEntries.map(\.name), ["src", "index.html"])
        XCTAssertEqual(vm.repoBrowsePath, "")

        await vm.browseRepository(path: "src")
        XCTAssertEqual(vm.repoBrowsePath, "src")
        XCTAssertEqual(vm.repoFileEntries.first?.path, "src/page.html")

        await vm.startPreview(path: "src/page.html")
        XCTAssertEqual(vm.activePreview?.path, "src/page.html")
        XCTAssertEqual(vm.activePreview?.url, "http://192.168.0.66:8790/src/page.html")
        let target = await bridge.receivedPreviewPath
        XCTAssertEqual(target, "src/page.html")
    }

    func testPromptPinsComposeBridgeCommandButNotTranscript() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let prompts = InMemoryCodingPromptStore()
        let vm = CodingViewModel(bridge: bridge, settings: settings, prompts: prompts)
        await vm.load()
        await vm.beginCodeViewSession()
        await vm.pinPath("src/App.tsx", isDirectory: false)

        vm.draft = "Add a button"
        await vm.send()

        XCTAssertEqual(vm.items.first?.text, "Add a button")
        let commands = await bridge.receivedCommands
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].contains("Focus on these paths"))
        XCTAssertTrue(commands[0].contains("src/App.tsx"))
        XCTAssertTrue(commands[0].contains("Add a button"))
        XCTAssertEqual(vm.promptHistory.first?.text, "Add a button")
    }

    func testKeepAndRevertReviewPaths() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        await vm.load()
        await vm.beginCodeViewSession()

        vm.draft = "edit files"
        await vm.send()

        XCTAssertEqual(vm.agentReview?.files.count, 1)
        XCTAssertEqual(vm.agentReview?.files.first?.path, "a.swift")
        XCTAssertTrue(vm.showDiff)

        await vm.keepReviewPaths(["a.swift"])
        let kept = await bridge.keptPaths
        XCTAssertEqual(kept, ["a.swift"])
        XCTAssertEqual(vm.agentReview?.files.first?.kept, true)

        await vm.revertReviewPaths(["a.swift"])
        let restored = await bridge.restoredPaths
        XCTAssertEqual(restored, ["a.swift"])
    }

    func testPublishDefaultsToAgentReviewPaths() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        vm.confirmPublish = { _, _ in true }
        await vm.load()
        await vm.beginCodeViewSession()
        vm.draft = "edit"
        await vm.send()

        XCTAssertEqual(vm.defaultPublishPaths(), ["a.swift"])
        await vm.publishPullRequest()
        let published = await bridge.lastPublishPaths
        XCTAssertEqual(published, ["a.swift"])
    }

    func testAutoOpenPreviewOpensOnceWhenReady() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "abcdef0123456789", autoOpenPreview: true)
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        var opened: [URL] = []
        vm.openURL = { url in
            opened.append(url)
            return true
        }
        await vm.load()
        await vm.startPreview(path: "src/page.html")
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.absoluteString, "http://192.168.0.66:8790/src/page.html")
    }

    func testFavoriteRepositoriesPersistAndFilterPicker() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        await vm.load()

        XCTAssertEqual(vm.repositories.count, 2)
        XCTAssertTrue(vm.favoriteRepositories.isEmpty)
        XCTAssertEqual(vm.filteredRepositories.count, 2)

        await vm.toggleFavoriteRepository("abcdef0123456789")
        XCTAssertTrue(vm.isFavoriteRepository("abcdef0123456789"))
        XCTAssertEqual(vm.favoriteRepositories.map(\.id), ["abcdef0123456789"])
        XCTAssertEqual(vm.filteredRepositories.map(\.id), ["1111111111111111"])
        let persisted = await settings.codingFavoriteRepoIds()
        XCTAssertEqual(persisted, ["abcdef0123456789"])

        vm.repoSearchQuery = "oth"
        XCTAssertEqual(vm.filteredRepositories.map(\.name), ["other"])
        XCTAssertTrue(vm.favoriteRepositories.isEmpty) // favorite name does not match query

        await vm.toggleFavoriteRepository("abcdef0123456789")
        XCTAssertFalse(vm.isFavoriteRepository("abcdef0123456789"))
        let cleared = await settings.codingFavoriteRepoIds()
        XCTAssertEqual(cleared, [])
    }

    func testRefreshPrunesStaleFavoriteRepoIds() async {
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(
            repoId: "abcdef0123456789",
            favoriteRepoIds: ["abcdef0123456789", "deadbeefdeadbeef"]
        )
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        await vm.load()
        XCTAssertEqual(vm.favoriteRepoIds, ["abcdef0123456789"])
        let pruned = await settings.codingFavoriteRepoIds()
        XCTAssertEqual(pruned, ["abcdef0123456789"])
    }

    func testStopPreviewInvalidatesStaleAutoOpen() async {
        let bridge = DirtyRepoBridge(previewBecomesReadyAfterPolls: 2)
        let settings = MemorySettings(repoId: "abcdef0123456789", autoOpenPreview: true)
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        var opened = 0
        vm.openURL = { _ in
            opened += 1
            return true
        }
        await vm.load()

        let start = Task { await vm.startPreview(path: "src/page.html") }
        try? await Task.sleep(for: .milliseconds(50))
        await vm.stopPreview()
        await start.value
        XCTAssertEqual(opened, 0)
    }

    func testWatchdogTransitionsAndRestartSession() async {
        let bridge = DirtyRepoBridge(streamDelaySeconds: 0.35)
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        vm.stallSoftSeconds = 0.05
        vm.stallHardSeconds = 0.15
        vm.stallPollSeconds = 0.03
        await vm.beginCodeViewSession()

        let sendTask = Task {
            vm.draft = "long job"
            await vm.send()
        }
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(vm.stallPhase, .looksStuck)

        await vm.restartSession()
        XCTAssertNil(vm.pinnedSessionId)
        XCTAssertEqual(vm.draft, "long job")
        XCTAssertEqual(vm.stallPhase, .idle)
        await sendTask.value
        let cancelled = await bridge.cancelStreamCount
        XCTAssertGreaterThanOrEqual(cancelled, 1)
    }

    func testLateSSEEventsAfterCancelAreIgnored() async {
        let bridge = DirtyRepoBridge(emitAfterCancel: true)
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        await vm.beginCodeViewSession()

        let sendTask = Task {
            vm.draft = "hello"
            await vm.send()
        }
        try? await Task.sleep(for: .milliseconds(30))
        await vm.cancel()
        await sendTask.value

        XCTAssertFalse(vm.items.contains(where: { $0.kind == .assistant && $0.text.contains("late") }))
    }

    func testConnectionLossPollsExistingRunWithoutResendingPrompt() async {
        let bridge = DirtyRepoBridge(disconnectAfterStart: true)
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings)
        vm.reconnectRetrySeconds = 0.01
        await vm.beginCodeViewSession()
        vm.draft = "make one safe edit"

        await vm.send()

        let commands = await bridge.receivedCommands
        let statusChecks = await bridge.runStatusCheckCount
        XCTAssertEqual(commands, ["make one safe edit"], "auto-recovery must never resend")
        XCTAssertEqual(statusChecks, 2)
        XCTAssertEqual(vm.runStatus, "finished")
        XCTAssertFalse(vm.isRunning)
    }

    func testTemplatesAndHistoryPersistPerRepo() async {
        let prompts = InMemoryCodingPromptStore()
        let bridge = DirtyRepoBridge()
        let settings = MemorySettings(repoId: "abcdef0123456789")
        let vm = CodingViewModel(bridge: bridge, settings: settings, prompts: prompts)
        await vm.load()
        await vm.beginCodeViewSession()

        vm.draft = "Ship a dark mode toggle"
        await vm.saveCurrentDraftAsTemplate(title: "Dark mode")
        XCTAssertEqual(vm.savedTemplates.first?.title, "Dark mode")

        await vm.pinPath("README.md", isDirectory: false)
        XCTAssertEqual(vm.pinnedPaths.map(\.path), ["README.md"])

        vm.draft = "history prompt"
        await vm.send()
        XCTAssertEqual(vm.promptHistory.first?.text, "history prompt")

        await vm.selectRepository("1111111111111111")
        XCTAssertTrue(vm.pinnedPaths.isEmpty)
        XCTAssertTrue(vm.savedTemplates.isEmpty)
        XCTAssertTrue(vm.promptHistory.isEmpty)

        await vm.selectRepository("abcdef0123456789")
        XCTAssertEqual(vm.pinnedPaths.map(\.path), ["README.md"])
        XCTAssertEqual(vm.savedTemplates.first?.title, "Dark mode")
        XCTAssertEqual(vm.promptHistory.first?.text, "history prompt")
    }
}

private actor MemorySettings: SettingsStoring {
    private var repoId: String?
    private var sessionIdsByRepo: [String: String]
    private var unscopedSessionId: String?
    private var autoOpenPreview: Bool
    private var favoriteRepoIds: [String]

    init(
        repoId: String?,
        sessionId: String? = nil,
        autoOpenPreview: Bool = false,
        favoriteRepoIds: [String] = []
    ) {
        self.repoId = repoId
        if let repoId, let sessionId {
            self.sessionIdsByRepo = [repoId: sessionId]
            self.unscopedSessionId = nil
        } else {
            self.sessionIdsByRepo = [:]
            self.unscopedSessionId = sessionId
        }
        self.autoOpenPreview = autoOpenPreview
        self.favoriteRepoIds = favoriteRepoIds
    }

    func spokenFollowUps() async -> Bool { false }
    func setSpokenFollowUps(_ enabled: Bool) async {}
    func codingSessionId() async -> String? {
        guard let repoId else { return unscopedSessionId }
        return sessionIdsByRepo[repoId]
    }
    func setCodingSessionId(_ value: String?) async {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
        if let repoId {
            sessionIdsByRepo[repoId] = normalized
        } else {
            unscopedSessionId = normalized
        }
    }
    func codingSelectedRepoId() async -> String? { repoId }
    func setCodingSelectedRepoId(_ value: String?) async {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        repoId = (trimmed?.isEmpty == false) ? trimmed : nil
    }
    func codingAutoOpenPreview() async -> Bool { autoOpenPreview }
    func setCodingAutoOpenPreview(_ enabled: Bool) async { autoOpenPreview = enabled }
    func codingFavoriteRepoIds() async -> [String] { favoriteRepoIds }
    func setCodingFavoriteRepoIds(_ ids: [String]) async { favoriteRepoIds = ids }
}

private actor DirtyRepoBridge: AgentBridging {
    private(set) var publishCallCount = 0
    private(set) var receivedImageCount = 0
    private(set) var receivedCommands: [String] = []
    private(set) var receivedSessionIds: [String?] = []
    private(set) var receivedPreviewPath: String?
    private(set) var keptPaths: [String] = []
    private(set) var restoredPaths: [String] = []
    private(set) var lastPublishPaths: [String] = []
    private(set) var cancelStreamCount = 0
    private(set) var runStatusCheckCount = 0
    private var reviewKept = false
    private let streamDelaySeconds: Double
    private let emitAfterCancel: Bool
    private let previewBecomesReadyAfterPolls: Int
    private let disconnectAfterStart: Bool
    private var previewPolls = 0
    private var cancelled = false

    init(
        streamDelaySeconds: Double = 0,
        emitAfterCancel: Bool = false,
        previewBecomesReadyAfterPolls: Int = 0,
        disconnectAfterStart: Bool = false
    ) {
        self.streamDelaySeconds = streamDelaySeconds
        self.emitAfterCancel = emitAfterCancel
        self.previewBecomesReadyAfterPolls = previewBecomesReadyAfterPolls
        self.disconnectAfterStart = disconnectAfterStart
    }

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
            payloadJSON: #"{"ok":true,"status":{"repoId":"\#(repoId)","name":"demo","branch":"main","upstream":"origin/main","ahead":0,"behind":0,"clean":false,"changedFiles":[{"path":"a.swift","status":"M","staged":false,"unstaged":true},{"path":"preexisting.txt","status":"M","staged":false,"unstaged":true}],"statusToken":"tok1234567890123456789012"}}"#
        )
    }

    func repositoryDiff(repoId: String) async -> BridgeResult {
        BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"repoId":"\#(repoId)","diff":"diff --git a/a.swift","truncated":false,"statusToken":"tok1234567890123456789012"}"#
        )
    }

    func listRepositoryFiles(repoId: String, path: String?) async -> BridgeResult {
        if path == "src" {
            return BridgeResult(
                ok: true,
                payloadJSON: #"{"ok":true,"repoId":"\#(repoId)","path":"src","entries":[{"name":"page.html","path":"src/page.html","kind":"file","size":42}]}"#
            )
        }
        return BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"repoId":"\#(repoId)","path":"","entries":[{"name":"src","path":"src","kind":"directory"},{"name":"index.html","path":"index.html","kind":"file","size":100}]}"#
        )
    }

    func startPreview(repoId: String, path: String?) async -> BridgeResult {
        receivedPreviewPath = path
        let target = path ?? ""
        previewPolls = 0
        let state = previewBecomesReadyAfterPolls > 0 ? "starting" : "ready"
        return BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"preview":{"repoId":"\#(repoId)","name":"page.html","path":"\#(target)","kind":"static","state":"\#(state)","port":8790,"url":"http://192.168.0.66:8790/src/page.html"}}"#
        )
    }

    func stopPreview(repoId: String) async -> BridgeResult {
        BridgeResult(ok: true, payloadJSON: #"{"ok":true}"#)
    }

    func listPreviews() async -> BridgeResult {
        previewPolls += 1
        let ready = previewPolls >= previewBecomesReadyAfterPolls
        let state = ready ? "ready" : "starting"
        return BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"previews":[{"repoId":"abcdef0123456789","name":"page.html","path":"src/page.html","kind":"static","state":"\#(state)","port":8790,"url":"http://192.168.0.66:8790/src/page.html"}]}"#
        )
    }

    func createBaseline(repoId: String) async -> BridgeResult {
        BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"baselineId":"base-\#(repoId)","repoId":"\#(repoId)"}"#
        )
    }

    func fetchAgentReview(repoId: String, baselineId: String) async -> BridgeResult {
        let kept = reviewKept ? "true" : "false"
        return BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"review":{"baselineId":"\#(baselineId)","repoId":"\#(repoId)","files":[{"path":"a.swift","change":"modified","diff":"@@ -1 +1 @@\n-old\n+new","truncated":false,"binary":false,"contentToken":"tok-a","kept":\#(kept)}],"pendingCount":\#(reviewKept ? 0 : 1),"keptCount":\#(reviewKept ? 1 : 0)}}"#
        )
    }

    func keepReviewPaths(repoId: String, baselineId: String, paths: [String]) async -> BridgeResult {
        keptPaths = paths
        reviewKept = true
        return BridgeResult(ok: true, payloadJSON: #"{"ok":true}"#)
    }

    func restoreReviewPaths(
        repoId: String,
        baselineId: String,
        paths: [String],
        contentTokens: [String: String]?
    ) async -> BridgeResult {
        restoredPaths = paths
        reviewKept = false
        return BridgeResult(ok: true, payloadJSON: #"{"ok":true}"#)
    }

    func publishRepository(repoId: String, request: BridgePublishRequest) async -> BridgeResult {
        publishCallCount += 1
        lastPublishPaths = request.paths ?? []
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

    func cancelActiveStream() async -> BridgeResult {
        cancelStreamCount += 1
        cancelled = true
        return BridgeResult(ok: true, payloadJSON: #"{"ok":true}"#)
    }

    func cancelCursorRun(runId: String) async -> BridgeResult {
        BridgeResult(ok: true, payloadJSON: #"{"ok":true}"#)
    }

    func cursorRunStatus(runId: String) async -> BridgeResult {
        runStatusCheckCount += 1
        let status = runStatusCheckCount == 1 ? "running" : "finished"
        return BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"sessionId":"agent-test","runId":"\#(runId)","status":"\#(status)","result":"ok"}"#
        )
    }

    func streamCursorRun(
        command: String,
        images: [CodingImageAttachment],
        sessionId: String?,
        workingDirectory: String?,
        repoId: String?,
        onEvent: @escaping @Sendable (CodingStreamEvent) async -> Void
    ) async -> BridgeResult {
        receivedImageCount = images.count
        receivedCommands.append(command)
        receivedSessionIds.append(sessionId)
        cancelled = false
        await onEvent(CodingStreamEvent(
            type: "status",
            status: "running",
            sessionId: "agent-test",
            runId: "run-test"
        ))
        if disconnectAfterStart {
            return BridgeResult(
                ok: false,
                payloadJSON: #"{"ok":false,"error":"bridge_connection_lost","sessionId":"agent-test","runId":"run-test","status":"running"}"#
            )
        }
        if streamDelaySeconds > 0 {
            let nanos = UInt64(streamDelaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        }
        if emitAfterCancel {
            try? await Task.sleep(nanoseconds: 80_000_000)
            await onEvent(
                CodingStreamEvent(type: "assistant_delta", text: "late assistant text")
            )
        }
        if cancelled {
            return BridgeResult(
                ok: true,
                payloadJSON: #"{"ok":true,"sessionId":"agent-test","runId":"run-test","status":"cancelled"}"#
            )
        }
        await onEvent(CodingStreamEvent(type: "done", status: "finished", sessionId: "agent-test", runId: "run-test"))
        return BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"sessionId":"agent-test","runId":"run-test","status":"finished","result":"ok"}"#
        )
    }
}
