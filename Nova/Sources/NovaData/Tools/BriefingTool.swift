import Foundation
import NovaCore
import NovaDomain
#if canImport(EventKit)
import EventKit
#endif

/// One-shot daily briefing: today's calendar events, open reminders, and
/// (optionally) weather for a city — so Nova can speak a single digest.
public struct BriefingTool: Tool {
    public let name = "daily_briefing"
    public let description = "Get a daily briefing: today's calendar events, open reminders, and optionally weather for a city."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"city":{"type":"string","description":"Optional city for weather"}},"additionalProperties":false}
    """
    private let weather: WeatherTool

    public init(weather: WeatherTool = WeatherTool()) {
        self.weather = weather
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let city: String? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(city: nil)

        var payload: [String: Any] = ["ok": true]
        payload["events"] = await Self.todaysEvents()
        payload["reminders"] = await Self.openReminders()
        if let city = args.city, !city.isEmpty {
            if let w = try? await weather.invoke(argumentsJSON: #"{"city":"\#(city)"}"#),
               let obj = try? JSONSerialization.jsonObject(with: Data(w.utf8)) {
                payload["weather"] = obj
            }
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    #if canImport(EventKit)
    private static func todaysEvents() async -> [[String: String]] {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else { return [] }
        let cal = Calendar.current
        let start = Date()
        let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(25)
            .map { ["title": $0.title ?? "(untitled)", "start": ISO8601.string(from: $0.startDate)] }
    }

    private static func openReminders() async -> [String] {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToReminders()) == true else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
        return reminders.compactMap { $0.title }.prefix(25).map { $0 }
    }
    #else
    private static func todaysEvents() async -> [[String: String]] { [] }
    private static func openReminders() async -> [String] { [] }
    #endif
}
