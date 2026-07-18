import Foundation
import NovaCore
import NovaDomain

/// Opens a specialist UI screen on the phone. Destinations are owned by one
/// agent — Remy can open the shopping list; Claude cannot — so misheard asks
/// do not drag another specialist's context into the session.
public struct OpenAppScreenTool: Tool {
    public let name = "open_app_screen"
    public let description = """
    Open a screen in this agent's part of the Nova app on the phone \
    (e.g. Remy: shopping_list, pantry, recipes; Claude: coding; Max: training; \
    Sage: wellness; Scholar: study). Only works for screens you own — if the \
    user wants another specialist's screen, tell them to talk to that agent \
    (or ask Nova to switch_agent). Do not invent a configuration error.
    """
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"destination":{"type":"string","description":"Screen id or phrase, e.g. shopping_list, pantry, coding, training, wellness, study."}},"required":["destination"],"additionalProperties":false}
    """

    private let activeAgentId: @Sendable () async -> UUID?
    private let activeAgentName: @Sendable () async -> String?
    private let open: @Sendable (AppScreenTarget) async -> Bool

    public init(
        activeAgentId: @escaping @Sendable () async -> UUID?,
        activeAgentName: @escaping @Sendable () async -> String?,
        open: @escaping @Sendable (AppScreenTarget) async -> Bool
    ) {
        self.activeAgentId = activeAgentId
        self.activeAgentName = activeAgentName
        self.open = open
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let destination: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let target = AppScreenCatalog.resolve(args.destination) else {
            let known = AppScreenCatalog.all.map(\.id).joined(separator: ", ")
            return #"{"ok":false,"error":"unknown_destination","hint":"Try one of: \#(Self.escape(known))"}"#
        }

        let agentId = await activeAgentId()
        let agentName = await activeAgentName() ?? "the active agent"
        guard let agentId else {
            return #"{"ok":false,"error":"no_active_agent"}"#
        }
        guard agentId == target.ownerAgentId else {
            let hint = "Only \(target.ownerName) can open \(target.title). Ask Nova to switch_agent to \(target.ownerName), then retry."
            return #"{"ok":false,"error":"wrong_agent","destination":"\#(Self.escape(target.id))","owner":"\#(Self.escape(target.ownerName))","active":"\#(Self.escape(agentName))","hint":"\#(Self.escape(hint))"}"#
        }

        let opened = await open(target)
        guard opened else {
            return #"{"ok":false,"error":"navigation_unavailable","destination":"\#(Self.escape(target.id))"}"#
        }
        return #"{"ok":true,"opened":"\#(Self.escape(target.id))","title":"\#(Self.escape(target.title))","route":"\#(Self.escape(target.routeKey))"}"#
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
