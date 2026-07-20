import XCTest
import NovaDomain
@testable import NovaFeatures

@MainActor
final class SettingsViewModelTests: XCTestCase {
    func testLANScanSelectsBridgeAndUpdatesActiveProfile() async {
        let home = BridgeProfile(
            name: "Home",
            baseURL: "http://192.168.66.10:8787",
            token: "token"
        )
        let store = SettingsStoreMock(
            baseURL: home.baseURL,
            token: home.token,
            profiles: [home]
        )
        let viewModel = SettingsViewModel(
            store: store,
            bridge: HealthyBridgeMock(),
            bridgeDiscovery: BridgeDiscoveryMock(url: "http://192.168.0.107:8787")
        )

        await viewModel.load()
        await viewModel.scanForLocalBridge()

        XCTAssertEqual(viewModel.bridgeBaseURL, "http://192.168.0.107:8787")
        XCTAssertEqual(viewModel.bridgeProfiles.first?.baseURL, "http://192.168.0.107:8787")
        let persistedURL = await store.bridgeBaseURL()
        let persistedProfiles = await store.bridgeProfiles()
        XCTAssertEqual(persistedURL, "http://192.168.0.107:8787")
        XCTAssertEqual(persistedProfiles.first?.baseURL, "http://192.168.0.107:8787")
    }

    func testProfilesCanBeRenamedAndRemoved() async {
        let home = BridgeProfile(name: "Home", baseURL: "http://home:8787", token: "token")
        let store = SettingsStoreMock(profiles: [home])
        let viewModel = SettingsViewModel(store: store, bridge: HealthyBridgeMock())
        await viewModel.load()

        await viewModel.renameBridgeProfile(home, to: "House")
        XCTAssertEqual(viewModel.bridgeProfiles.map(\.name), ["House"])
        let renamedProfiles = await store.bridgeProfiles()
        XCTAssertEqual(renamedProfiles.map(\.name), ["House"])

        guard let renamed = viewModel.bridgeProfiles.first else {
            return XCTFail("Renamed profile missing")
        }
        await viewModel.deleteBridgeProfile(renamed)
        XCTAssertTrue(viewModel.bridgeProfiles.isEmpty)
        let remainingProfiles = await store.bridgeProfiles()
        XCTAssertTrue(remainingProfiles.isEmpty)
    }

    func testHealthPopulatesBridgeSetupChecklist() async {
        let store = SettingsStoreMock(
            baseURL: "https://pc.ts.net",
            token: "secret"
        )
        let viewModel = SettingsViewModel(store: store, bridge: HealthyBridgeMock())
        await viewModel.load()

        XCTAssertTrue(viewModel.bridgeReachable)
        XCTAssertEqual(viewModel.repoRootCount, 2)
        XCTAssertEqual(viewModel.tailscaleIp, "100.64.1.2")
        XCTAssertEqual(viewModel.previewRemoteReady, true)
        XCTAssertEqual(viewModel.bridgeDefaultCwd, #"C:\src"#)
        let missing = viewModel.bridgeSetupSteps.filter { $0.state == .missing }
        XCTAssertTrue(missing.isEmpty, "Expected full readiness, got missing: \(missing.map(\.id))")
        XCTAssertNil(viewModel.bridgeSetupNextAction)
        XCTAssertGreaterThanOrEqual(viewModel.bridgeSetupReadyCount, 8)
    }

    func testLoadAutoDiscoversWhenSavedBridgeIsUnreachable() async throws {
        let store = SettingsStoreMock(
            baseURL: "http://192.168.1.20:8787",
            token: "keep-me"
        )
        let viewModel = SettingsViewModel(
            store: store,
            bridge: UnhealthyBridgeMock(),
            bridgeDiscovery: BridgeDiscoveryMock(url: "http://192.168.1.44:8787")
        )

        await viewModel.load()
        for _ in 0..<50 where viewModel.bridgeBaseURL != "http://192.168.1.44:8787" {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(viewModel.bridgeBaseURL, "http://192.168.1.44:8787")
        let savedURL = await store.bridgeBaseURL()
        let savedToken = await store.bridgeToken()
        XCTAssertEqual(savedURL, "http://192.168.1.44:8787")
        XCTAssertEqual(savedToken, "keep-me")
    }
}

private actor BridgeDiscoveryMock: BridgeDiscovering {
    let url: String?
    init(url: String?) { self.url = url }
    func discoverBridgeURL() async -> String? { url }
}

private struct HealthyBridgeMock: AgentBridging {
    func isConfigured() async -> Bool { true }
    func health() async -> BridgeResult {
        BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"service":"nova-bridge","openaiConfigured":true,"cursorConfigured":true,"gitReady":true,"ghReady":true,"repoRootCount":2,"previewRemoteReady":true,"tailscaleIp":"100.64.1.2","defaultCwd":"C:\\src","tokenConfigured":true}"#
        )
    }
}

private struct UnhealthyBridgeMock: AgentBridging {
    func isConfigured() async -> Bool { true }
    func health() async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"offline"}"#)
    }
}

private actor SettingsStoreMock: SettingsStoring {
    private var storedBaseURL: String?
    private var storedToken: String?
    private var storedProfiles: [BridgeProfile]

    init(baseURL: String? = nil, token: String? = nil, profiles: [BridgeProfile] = []) {
        storedBaseURL = baseURL
        storedToken = token
        storedProfiles = profiles
    }

    func spokenFollowUps() async -> Bool { false }
    func setSpokenFollowUps(_ enabled: Bool) async {}
    func bridgeBaseURL() async -> String? { storedBaseURL }
    func setBridgeBaseURL(_ value: String?) async { storedBaseURL = value }
    func bridgeToken() async -> String? { storedToken }
    func setBridgeToken(_ value: String?) async { storedToken = value }
    func bridgeProfiles() async -> [BridgeProfile] { storedProfiles }
    func setBridgeProfiles(_ profiles: [BridgeProfile]) async { storedProfiles = profiles }
}
