import XCTest
@testable import NovaData
@testable import NovaDomain

final class SelfCodeToolTests: XCTestCase {
    func testSearchDelegatesToBridge() async throws {
        let bridge = SelfCodeBridge()
        let tool = InspectNovaCodebaseTool(bridge: bridge)

        let output = try await tool.invoke(
            argumentsJSON: #"{"action":"search","query":"video recording"}"#
        )

        XCTAssertTrue(output.contains("VideoRecordingTools.swift"))
        let query = await bridge.lastSearchQuery
        XCTAssertEqual(query, "video recording")
    }

    func testReadDelegatesBoundedRange() async throws {
        let bridge = SelfCodeBridge()
        let tool = InspectNovaCodebaseTool(bridge: bridge)

        _ = try await tool.invoke(
            argumentsJSON: #"{"action":"read","path":"Nova/Sources/Foo.swift","start_line":5,"end_line":12}"#
        )

        let read = await bridge.lastRead
        XCTAssertEqual(read?.path, "Nova/Sources/Foo.swift")
        XCTAssertEqual(read?.start, 5)
        XCTAssertEqual(read?.end, 12)
    }

    func testBridgeFailureThrowsInsteadOfReportingToolSuccess() async {
        let bridge = SelfCodeBridge(fail: true)
        let tool = InspectNovaCodebaseTool(bridge: bridge)

        do {
            _ = try await tool.invoke(
                argumentsJSON: #"{"action":"search","query":"camera"}"#
            )
            XCTFail("Expected bridge failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("source lookup unavailable"))
        }
    }
}

private actor SelfCodeBridge: AgentBridging {
    struct Read: Sendable {
        let path: String
        let start: Int
        let end: Int
    }

    private let fail: Bool
    private(set) var lastSearchQuery: String?
    private(set) var lastRead: Read?

    init(fail: Bool = false) {
        self.fail = fail
    }

    func isConfigured() async -> Bool { !fail }

    func searchNovaCode(query: String) async -> BridgeResult {
        lastSearchQuery = query
        if fail {
            return BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"offline"}"#)
        }
        return BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"matches":[{"path":"Nova/Sources/VideoRecordingTools.swift","line":1}]}"#
        )
    }

    func readNovaCode(path: String, startLine: Int, endLine: Int) async -> BridgeResult {
        lastRead = Read(path: path, start: startLine, end: endLine)
        return BridgeResult(ok: true, payloadJSON: #"{"ok":true,"content":"evidence"}"#)
    }
}
