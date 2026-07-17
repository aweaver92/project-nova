import Foundation
import NovaDomain

public struct LogWellnessCheckinTool: Tool {
    public let name = "log_wellness_checkin"
    public let description = "Log a wellness / mood check-in (mood 1–5 plus optional note)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"mood":{"type":"integer","description":"Mood from 1 (low) to 5 (great)."},"note":{"type":"string"}},"required":["mood"],"additionalProperties":false}
    """
    private let store: any WellnessStoring
    public init(store: any WellnessStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let mood: Int; let note: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let entry = await store.log(mood: args.mood, note: args.note)
        return #"{"ok":true,"id":"\#(entry.id.uuidString)","mood":\#(entry.mood)}"#
    }
}

public struct WellnessHistoryTool: Tool {
    public let name = "wellness_history"
    public let description = "Read recent wellness / mood check-ins."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"limit":{"type":"integer"}},"additionalProperties":false}
    """
    private let store: any WellnessStoring
    public init(store: any WellnessStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let limit: Int? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(limit: nil)
        let items = await store.recent(limit: args.limit ?? 10)
        let payload: [[String: Any]] = items.map {
            var d: [String: Any] = [
                "id": $0.id.uuidString,
                "mood": $0.mood,
                "at": ISO8601DateFormatter().string(from: $0.at)
            ]
            if let n = $0.note { d["note"] = n }
            return d
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "count": payload.count, "checkins": payload])
        return String(decoding: data, as: UTF8.self)
    }
}
