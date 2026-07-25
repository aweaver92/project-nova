import Foundation
import NovaCore
import NovaDomain

/// Hands the live conversation to another persona (or back to Nova).
/// Wired so voice can switch even when Listen has wake-word gating off —
/// without this, the model often invents a "configuration" failure.
public struct SwitchAgentTool: Tool {
    public let name = "switch_agent"
    public let description = """
    Hand the conversation to a specialist (Claude, Max, Sage, Remy, Scholar) or back to Nova. \
    Call this whenever the user asks to talk to / switch to another agent. \
    Do not claim a configuration problem — this tool performs the switch.
    """
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"agent":{"type":"string","description":"Agent name: Nova, Claude, Max, Sage, Remy, or Scholar."}},"required":["agent"],"additionalProperties":false}
    """

    private let perform: @Sendable (String) async -> String

    public init(perform: @escaping @Sendable (String) async -> String) {
        self.perform = perform
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let agent: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        return await perform(args.agent)
    }
}
