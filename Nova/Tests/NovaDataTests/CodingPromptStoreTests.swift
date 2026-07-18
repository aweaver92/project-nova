import XCTest
@testable import NovaData
@testable import NovaDomain

final class CodingPromptStoreTests: XCTestCase {
    func testRoundTripTemplatesHistoryAndPins() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-coding-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("coding-prompts.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileCodingPromptStore(url: url)
        let repoId = "abcdef0123456789"

        await store.upsertTemplate(
            CodingPromptTemplate(title: "Fix tests", body: "Fix failing tests"),
            repoId: repoId
        )
        await store.appendHistory(
            CodingPromptHistoryEntry(text: "Add dark mode"),
            repoId: repoId
        )
        await store.setPinnedPaths(
            [
                CodingContextPin(path: "src", kind: "directory"),
                CodingContextPin(path: "README.md", kind: "file"),
            ],
            repoId: repoId
        )

        let reloaded = FileCodingPromptStore(url: url)
        let state = await reloaded.state(repoId: repoId)
        XCTAssertEqual(state.templates.first?.title, "Fix tests")
        XCTAssertEqual(state.history.first?.text, "Add dark mode")
        XCTAssertEqual(state.pinnedPaths.map(\.path), ["src", "README.md"])

        let other = await reloaded.state(repoId: "1111111111111111")
        XCTAssertTrue(other.templates.isEmpty)
        XCTAssertTrue(other.history.isEmpty)
        XCTAssertTrue(other.pinnedPaths.isEmpty)
    }

    func testCapsPinsHistoryAndTemplates() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-coding-prompt-caps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("coding-prompts.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileCodingPromptStore(url: url)
        let repoId = "abcdef0123456789"

        await store.setPinnedPaths(
            (0..<5).map { CodingContextPin(path: "f\($0).swift", kind: "file") },
            repoId: repoId
        )
        let pins = await store.state(repoId: repoId)
        XCTAssertEqual(pins.pinnedPaths.count, 3)

        for i in 0..<55 {
            await store.appendHistory(
                CodingPromptHistoryEntry(text: "prompt \(i)"),
                repoId: repoId
            )
        }
        let history = await store.state(repoId: repoId)
        XCTAssertEqual(history.history.count, 50)
        XCTAssertEqual(history.history.first?.text, "prompt 54")

        for i in 0..<25 {
            await store.upsertTemplate(
                CodingPromptTemplate(title: "t\(i)", body: "body \(i)"),
                repoId: repoId
            )
        }
        let templates = await store.state(repoId: repoId)
        XCTAssertEqual(templates.templates.count, 20)
    }
}
