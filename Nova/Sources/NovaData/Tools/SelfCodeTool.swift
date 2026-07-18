import Foundation
import NovaCore
import NovaDomain

/// Read-only retrieval over Nova's own app + bridge source. The bridge locates
/// the Nova repository by marker files, so this never follows the Coding tab to
/// an unrelated selected repository.
public struct InspectNovaCodebaseTool: Tool {
    public let name = "inspect_nova_codebase"
    public let description = """
    Search or read Nova's own source code to answer questions about what the app supports, how a feature works, where a capability is implemented, or whether something is actually available. ALWAYS use this tool before making claims about Nova's capabilities or implementation. First search with 2–6 specific code keywords; then read the most relevant path and line range. Base the answer only on returned evidence, mention file citations when useful, and say the code does not confirm it when evidence is missing. This tool is strictly read-only.
    """
    public let requiresConfirmation = false
    public let parametersJSON = """
    {
      "type":"object",
      "properties":{
        "action":{
          "type":"string",
          "enum":["search","read"],
          "description":"Use search first, then read exact evidence."
        },
        "query":{
          "type":"string",
          "description":"For search: 2–6 concrete implementation keywords, such as 'video recording glasses camera'."
        },
        "path":{
          "type":"string",
          "description":"For read: repository-relative path returned by search."
        },
        "start_line":{
          "type":"integer",
          "minimum":1,
          "description":"First line to read (default 1)."
        },
        "end_line":{
          "type":"integer",
          "minimum":1,
          "description":"Last line to read, capped by the bridge (default start+119)."
        }
      },
      "required":["action"],
      "additionalProperties":false
    }
    """

    private let bridge: any AgentBridging

    public init(bridge: any AgentBridging) {
        self.bridge = bridge
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let action: String
            let query: String?
            let path: String?
            let start_line: Int?
            let end_line: Int?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        switch args.action {
        case "search":
            let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty else {
                throw NovaError.tool("inspect_nova_codebase search requires query")
            }
            return try Self.requireSuccess(await bridge.searchNovaCode(query: query))
        case "read":
            let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !path.isEmpty else {
                throw NovaError.tool("inspect_nova_codebase read requires path")
            }
            let start = max(1, args.start_line ?? 1)
            let end = max(start, args.end_line ?? (start + 119))
            return try Self.requireSuccess(
                await bridge.readNovaCode(path: path, startLine: start, endLine: end)
            )
        default:
            throw NovaError.tool("inspect_nova_codebase action must be search or read")
        }
    }

    private static func requireSuccess(_ result: BridgeResult) throws -> String {
        guard result.ok else {
            throw NovaError.tool(
                "Nova source lookup unavailable: \(String(result.payloadJSON.prefix(300)))"
            )
        }
        return result.payloadJSON
    }
}
