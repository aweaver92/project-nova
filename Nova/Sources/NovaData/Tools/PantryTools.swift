import Foundation
import NovaDomain

public struct AddPantryItemTool: Tool {
    public let name = "add_pantry_item"
    public let description = "Add or update an item in the user's pantry / fridge inventory."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"name":{"type":"string"},"quantity":{"type":"string"},"notes":{"type":"string"},"category":{"type":"string","enum":["produce","dairy","protein","pantry","frozen","other"]},"location":{"type":"string","enum":["fridge","freezer","pantry","counter"]},"stock_level":{"type":"string","enum":["ok","low","out"]},"expires_at":{"type":"string","description":"ISO-8601 date"}},"required":["name"],"additionalProperties":false}
    """
    private let store: any PantryStoring
    public init(store: any PantryStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let name: String
            let quantity: String?
            let notes: String?
            let category: String?
            let location: String?
            let stock_level: String?
            let expires_at: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let item = await store.upsert(PantryItem(
            name: args.name,
            quantity: args.quantity,
            notes: args.notes,
            category: args.category.flatMap(PantryCategory.init(rawValue:)) ?? .other,
            location: args.location.flatMap(PantryLocation.init(rawValue:)) ?? .pantry,
            stockLevel: args.stock_level.flatMap(StockLevel.init(rawValue:)) ?? .ok,
            expiresAt: Self.parseDate(args.expires_at)
        ))
        return #"{"ok":true,"id":"\#(item.id.uuidString)","name":"\#(Self.escape(item.name))"}"#
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        if let d = iso.date(from: String(raw.prefix(10))) { return d }
        let full = ISO8601DateFormatter()
        return full.date(from: raw)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public struct UpdatePantryItemTool: Tool {
    public let name = "update_pantry_item"
    public let description = "Update fields on an existing pantry item by id or name."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"quantity":{"type":"string"},"notes":{"type":"string"},"category":{"type":"string","enum":["produce","dairy","protein","pantry","frozen","other"]},"location":{"type":"string","enum":["fridge","freezer","pantry","counter"]},"stock_level":{"type":"string","enum":["ok","low","out"]},"expires_at":{"type":"string"}},"additionalProperties":false}
    """
    private let store: any PantryStoring
    public init(store: any PantryStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let id: String?
            let name: String?
            let quantity: String?
            let notes: String?
            let category: String?
            let location: String?
            let stock_level: String?
            let expires_at: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let all = await store.all()
        let existing: PantryItem?
        if let id = args.id.flatMap(UUID.init(uuidString:)) {
            existing = all.first { $0.id == id }
        } else if let name = args.name {
            existing = all.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        } else {
            existing = nil
        }
        guard var item = existing else { return #"{"ok":false,"error":"not_found"}"# }
        if let name = args.name, !name.isEmpty { item.name = name }
        if let q = args.quantity { item.quantity = q }
        if let n = args.notes { item.notes = n }
        if let c = args.category.flatMap(PantryCategory.init(rawValue:)) { item.category = c }
        if let l = args.location.flatMap(PantryLocation.init(rawValue:)) { item.location = l }
        if let s = args.stock_level.flatMap(StockLevel.init(rawValue:)) { item.stockLevel = s }
        if args.expires_at != nil { item.expiresAt = AddPantryItemTool.parseDate(args.expires_at) }
        let saved = await store.upsert(item)
        return #"{"ok":true,"id":"\#(saved.id.uuidString)"}"#
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
            var d: [String: Any] = [
                "id": $0.id.uuidString,
                "name": $0.name,
                "category": $0.category.rawValue,
                "location": $0.location.rawValue,
                "stock_level": $0.stockLevel.rawValue
            ]
            if let q = $0.quantity { d["quantity"] = q }
            if let n = $0.notes { d["notes"] = n }
            if let e = $0.expiresAt {
                d["expires_at"] = ISO8601DateFormatter().string(from: e)
            }
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
