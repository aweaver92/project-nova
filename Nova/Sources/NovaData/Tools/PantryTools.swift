import Foundation
import NovaDomain

public struct AddPantryItemTool: Tool {
    public let name = "add_pantry_item"
    public let description = "Add or update an item in the user's pantry / fridge inventory."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"name":{"type":"string"},"quantity":{"type":"string"},"notes":{"type":"string"}},"required":["name"],"additionalProperties":false}
    """
    private let store: any PantryStoring
    public init(store: any PantryStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let name: String; let quantity: String?; let notes: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let item = await store.upsert(PantryItem(name: args.name, quantity: args.quantity, notes: args.notes))
        return #"{"ok":true,"id":"\#(item.id.uuidString)","name":"\#(Self.escape(item.name))"}"#
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public struct ListPantryTool: Tool {
    public let name = "list_pantry"
    public let description = "List what's in the user's pantry / fridge inventory."
    public let requiresConfirmation = false
    private let store: any PantryStoring
    public init(store: any PantryStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        let items = await store.all()
        let payload: [[String: Any]] = items.map {
            var d: [String: Any] = ["id": $0.id.uuidString, "name": $0.name]
            if let q = $0.quantity { d["quantity"] = q }
            if let n = $0.notes { d["notes"] = n }
            return d
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "count": payload.count, "items": payload])
        return String(decoding: data, as: UTF8.self)
    }
}

public struct RemovePantryItemTool: Tool {
    public let name = "remove_pantry_item"
    public let description = "Remove an item from the pantry by id or name."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"}},"additionalProperties":false}
    """
    private let store: any PantryStoring
    public init(store: any PantryStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let id: String?; let name: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let all = await store.all()
        if let id = args.id.flatMap(UUID.init(uuidString:)), all.contains(where: { $0.id == id }) {
            await store.delete(id: id)
            return #"{"ok":true}"#
        }
        if let name = args.name {
            if let match = all.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                await store.delete(id: match.id)
                return #"{"ok":true}"#
            }
        }
        return #"{"ok":false,"error":"not_found"}"#
    }
}
