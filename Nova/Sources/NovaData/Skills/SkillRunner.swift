import Foundation
import NovaCore
import NovaDomain

/// Runs a Skill's steps. Deterministic steps (reminder, calendar, note, open URL,
/// timer) execute locally via the existing tools/stores and injected app
/// callbacks; `.say` and `.freeform` steps are returned for the model to speak or
/// carry out, giving the hybrid execution model.
public struct SkillRunner: SkillRunning {
    /// Opens a deep link / URL from the app layer. Returns whether it succeeded.
    public typealias URLOpener = @Sendable (URL) async -> Bool
    /// Starts an in-app/local-notification timer. Returns whether it was scheduled.
    public typealias TimerStarter = @Sendable (_ seconds: Int, _ label: String) async -> Bool
    /// Performs an outbound HTTP request for `.webhook` steps. Returns success.
    public typealias WebhookCaller = @Sendable (_ request: URLRequest) async -> Bool
    /// Pauses execution for `.delay` steps (injectable so tests don't really wait).
    public typealias Sleeper = @Sendable (_ seconds: TimeInterval) async -> Void

    /// Upper bound on a single `.delay` step so a runaway skill can't hang.
    public static let maxDelaySeconds = 300

    private let notes: any NoteStoring
    private let reminderTool: CreateReminderTool
    private let calendarTool: CreateCalendarEventTool
    private let openURL: URLOpener?
    private let startTimer: TimerStarter?
    private let callWebhook: WebhookCaller?
    private let sleep: Sleeper

    public init(
        notes: any NoteStoring,
        openURL: URLOpener? = nil,
        startTimer: TimerStarter? = nil,
        callWebhook: WebhookCaller? = nil,
        sleep: Sleeper? = nil,
        reminderTool: CreateReminderTool = CreateReminderTool(),
        calendarTool: CreateCalendarEventTool = CreateCalendarEventTool()
    ) {
        self.notes = notes
        self.openURL = openURL
        self.startTimer = startTimer
        self.callWebhook = callWebhook
        self.sleep = sleep ?? { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        self.reminderTool = reminderTool
        self.calendarTool = calendarTool
    }

    public func run(_ skill: Skill) async -> SkillRunResult {
        var result = SkillRunResult()
        for step in skill.steps {
            switch step.kind {
            case .reminder:
                await runReminder(step, into: &result)
            case .calendarEvent:
                await runCalendar(step, into: &result)
            case .note:
                await runNote(step, into: &result)
            case .openURL:
                await runOpenURL(step, into: &result)
            case .timer:
                await runTimer(step, into: &result)
            case .webhook:
                await runWebhook(step, into: &result)
            case .delay:
                await runDelay(step, into: &result)
            case .say:
                if !step.text.isEmpty { result.sayLines.append(step.text) }
            case .freeform:
                if !step.text.isEmpty { result.freeform.append(step.text) }
            }
        }
        return result
    }

    // MARK: - Deterministic steps

    private func runReminder(_ step: SkillStep, into result: inout SkillRunResult) async {
        guard !step.text.isEmpty else { return }
        var args: [String: Any] = ["title": step.text]
        if let due = step.dateISO { args["dueISO8601"] = due }
        if let json = try? JSONSerialization.data(withJSONObject: args),
           (try? await reminderTool.invoke(argumentsJSON: String(decoding: json, as: UTF8.self))) != nil {
            result.summaryLines.append("set a reminder to \(step.text)")
        } else {
            result.summaryLines.append("couldn't set the reminder to \(step.text)")
        }
    }

    private func runCalendar(_ step: SkillStep, into result: inout SkillRunResult) async {
        guard !step.text.isEmpty, let start = step.dateISO else { return }
        var args: [String: Any] = ["title": step.text, "startISO8601": start]
        if let mins = step.durationMinutes { args["durationMinutes"] = mins }
        if let json = try? JSONSerialization.data(withJSONObject: args),
           (try? await calendarTool.invoke(argumentsJSON: String(decoding: json, as: UTF8.self))) != nil {
            result.summaryLines.append("added \(step.text) to your calendar")
        } else {
            result.summaryLines.append("couldn't add \(step.text) to your calendar")
        }
    }

    private func runNote(_ step: SkillStep, into result: inout SkillRunResult) async {
        guard !step.text.isEmpty else { return }
        await notes.save(step.text)
        result.summaryLines.append("saved a note")
    }

    private func runOpenURL(_ step: SkillStep, into result: inout SkillRunResult) async {
        guard let raw = step.url, let url = URL(string: raw) else { return }
        if let openURL, await openURL(url) {
            result.summaryLines.append("opened \(raw)")
        } else {
            result.summaryLines.append("couldn't open \(raw)")
        }
    }

    private func runTimer(_ step: SkillStep, into result: inout SkillRunResult) async {
        guard let seconds = step.seconds, seconds > 0 else { return }
        let label = step.text.isEmpty ? "Timer" : step.text
        if let startTimer, await startTimer(seconds, label) {
            result.summaryLines.append("started a \(seconds)-second timer")
        } else {
            result.summaryLines.append("couldn't start the timer")
        }
    }

    private func runWebhook(_ step: SkillStep, into result: inout SkillRunResult) async {
        guard let raw = step.url, let url = URL(string: raw) else { return }
        let method = (step.httpMethod ?? "GET").uppercased()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if method != "GET", !step.text.isEmpty {
            request.httpBody = Data(step.text.utf8)
            // Best-effort content type: JSON if the body looks like JSON.
            let trimmed = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isJSON = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
            request.setValue(isJSON ? "application/json" : "text/plain", forHTTPHeaderField: "Content-Type")
        }
        if let callWebhook, await callWebhook(request) {
            result.summaryLines.append("called the webhook")
        } else {
            result.summaryLines.append("couldn't reach the webhook")
        }
    }

    private func runDelay(_ step: SkillStep, into result: inout SkillRunResult) async {
        guard let seconds = step.seconds, seconds > 0 else { return }
        let capped = min(seconds, Self.maxDelaySeconds)
        await sleep(TimeInterval(capped))
        result.summaryLines.append("waited \(capped) second\(capped == 1 ? "" : "s")")
    }
}
