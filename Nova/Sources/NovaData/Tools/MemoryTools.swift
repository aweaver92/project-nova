import Foundation
import NovaCore
import NovaDomain

/// Store a durable fact about the user.
public struct RememberFactTool: Tool {
    public let name = "remember_fact"
    public let description = "Save a durable fact about the user (preference, name, ongoing context) to remember across sessions."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"fact":{"type":"string","description":"A concise fact to remember, e.g. 'User's dog is named Cooper'"}},"required":["fact"],"additionalProperties":false}
    """
    private let store: FileFactStore
    public init(store: FileFactStore) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let fact: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let added = await store.add(args.fact)
        return #"{"ok":true,"added":\#(added)}"#
    }
}

/// Recall everything Nova knows about the user.
public struct RecallFactsTool: Tool {
    public let name = "recall_facts"
    public let description = "List the durable facts Nova has stored about the user."
    public let requiresConfirmation = false
    private let store: FileFactStore
    public init(store: FileFactStore) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        let facts = await store.all()
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "facts": facts])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Forget stored facts matching a phrase.
public struct ForgetFactTool: Tool {
    public let name = "forget_fact"
    public let description = "Remove stored facts about the user that match a phrase."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"match":{"type":"string","description":"Text to match; facts containing it are removed"}},"required":["match"],"additionalProperties":false}
    """
    private let store: FileFactStore
    public init(store: FileFactStore) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let match: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let removed = await store.remove(matching: args.match)
        return #"{"ok":true,"removed":\#(removed)}"#
    }
}
