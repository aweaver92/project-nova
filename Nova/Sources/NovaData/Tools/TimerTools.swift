import Foundation
import NovaDomain

public struct SetTimerTool: Tool {
    public let name = "set_timer"
    public let description = "Start a countdown timer that fires a local notification when done (rest between sets, cook time, breathing round, etc.)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"seconds":{"type":"integer","description":"Countdown length in seconds."},"label":{"type":"string","description":"Optional label, e.g. 'Rest' or 'Pasta'."}},"required":["seconds"],"additionalProperties":false}
    """
    private let timers: any TimerScheduling
    public init(timers: any TimerScheduling) { self.timers = timers }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let seconds: Int; let label: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let timer = await timers.schedule(seconds: args.seconds, label: args.label ?? "Timer") else {
            return #"{"ok":false,"error":"timer_permission_or_schedule_failed"}"#
        }
        return #"{"ok":true,"id":"\#(timer.id.uuidString)","label":"\#(Self.escape(timer.label))","seconds":\#(timer.seconds)}"#
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public struct CancelTimerTool: Tool {
    public let name = "cancel_timer"
    public let description = "Cancel a running timer by id or label. Omit both to cancel all timers."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"id":{"type":"string","description":"Timer id from set_timer / list_timers."},"label":{"type":"string","description":"Timer label to cancel."}},"additionalProperties":false}
    """
    private let timers: any TimerScheduling
    public init(timers: any TimerScheduling) { self.timers = timers }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let id: String?; let label: String? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(id: nil, label: nil)
        let uuid = args.id.flatMap(UUID.init(uuidString:))
        let ok = await timers.cancel(id: uuid, label: args.label)
        return #"{"ok":\#(ok)}"#
    }
}

public struct ListTimersTool: Tool {
    public let name = "list_timers"
    public let description = "List currently running countdown timers and how many seconds remain."
    public let requiresConfirmation = false
    private let timers: any TimerScheduling
    public init(timers: any TimerScheduling) { self.timers = timers }

    public func invoke(argumentsJSON: String) async throws -> String {
        let items = await timers.list()
        let payload: [[String: Any]] = items.map {
            [
                "id": $0.id.uuidString,
                "label": $0.label,
                "seconds": $0.seconds,
                "remaining_seconds": $0.remainingSeconds
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "count": payload.count, "timers": payload])
        return String(decoding: data, as: UTF8.self)
    }
}
