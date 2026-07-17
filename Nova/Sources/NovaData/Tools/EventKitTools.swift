import Foundation
import NovaCore
import NovaDomain

#if canImport(EventKit)
import EventKit

/// Creates an iOS Reminder via EventKit.
public struct CreateReminderTool: Tool {
    public let name = "create_reminder"
    public let description = "Create a reminder in the user's iOS Reminders, optionally with a due date/time."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"title":{"type":"string","description":"What to be reminded about"},"dueISO8601":{"type":"string","description":"Optional due date/time in ISO8601, e.g. 2026-07-18T17:00:00Z"}},"required":["title"],"additionalProperties":false}
    """
    public init() {}

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let title: String; let dueISO8601: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))

        let store = EKEventStore()
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw NovaError.tool("Reminders access denied") }

        let reminder = EKReminder(eventStore: store)
        reminder.title = args.title
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due = ISO8601.date(from: args.dueISO8601) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return #"{"ok":true,"title":"\#(Self.escape(args.title))"}"#
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Lists upcoming calendar events within a window.
public struct ListCalendarEventsTool: Tool {
    public let name = "list_calendar_events"
    public let description = "List the user's upcoming calendar events within the next N days (default 1)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"days":{"type":"integer","description":"How many days ahead to include (default 1)"}},"additionalProperties":false}
    """
    public init() {}

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let days: Int? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(days: nil)
        let days = max(1, args.days ?? 1)

        let store = EKEventStore()
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { throw NovaError.tool("Calendar access denied") }

        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(25)

        let items = events.map { ev -> [String: Any] in
            [
                "title": ev.title ?? "(untitled)",
                "start": ISO8601.string(from: ev.startDate),
                "location": ev.location ?? ""
            ]
        }
        let payload: [String: Any] = ["ok": true, "count": items.count, "events": items]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Creates a calendar event.
public struct CreateCalendarEventTool: Tool {
    public let name = "create_calendar_event"
    public let description = "Create a calendar event with a title and start time."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"title":{"type":"string"},"startISO8601":{"type":"string","description":"Start time in ISO8601"},"durationMinutes":{"type":"integer","description":"Event length in minutes (default 60)"}},"required":["title","startISO8601"],"additionalProperties":false}
    """
    public init() {}

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let title: String; let startISO8601: String; let durationMinutes: Int? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let start = ISO8601.date(from: args.startISO8601) else {
            throw NovaError.tool("Invalid start time")
        }

        let store = EKEventStore()
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { throw NovaError.tool("Calendar access denied") }

        let event = EKEvent(eventStore: store)
        event.title = args.title
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval((args.durationMinutes ?? 60) * 60))
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        return #"{"ok":true,"title":"\#(CreateReminderTool.escape(args.title))","start":"\#(ISO8601.string(from: start))"}"#
    }
}
#else
public struct CreateReminderTool: Tool {
    public let name = "create_reminder"
    public let description = "Create a reminder (unavailable on this platform)."
    public let requiresConfirmation = false
    public init() {}
    public func invoke(argumentsJSON: String) async throws -> String { #"{"ok":false,"error":"unavailable"}"# }
}
public struct ListCalendarEventsTool: Tool {
    public let name = "list_calendar_events"
    public let description = "List calendar events (unavailable on this platform)."
    public let requiresConfirmation = false
    public init() {}
    public func invoke(argumentsJSON: String) async throws -> String { #"{"ok":false,"error":"unavailable"}"# }
}
public struct CreateCalendarEventTool: Tool {
    public let name = "create_calendar_event"
    public let description = "Create a calendar event (unavailable on this platform)."
    public let requiresConfirmation = false
    public init() {}
    public func invoke(argumentsJSON: String) async throws -> String { #"{"ok":false,"error":"unavailable"}"# }
}
#endif
