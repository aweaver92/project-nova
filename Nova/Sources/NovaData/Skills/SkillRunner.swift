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
    /// Captures a glasses still and returns any text read from it (via OCR) for
    /// `.capture` steps. `label` is the step's optional caption. Injectable so the
    /// data layer owns the camera + OCR while the runner stays testable.
    public typealias Capturer = @Sendable (_ label: String) async -> String?
    /// Confirmation gate for steps with `requiresConfirmation == true`.
    public typealias Confirmer = @Sendable (_ title: String, _ detail: String) async -> Bool

    /// Upper bound on a single `.delay` step so a runaway skill can't hang.
    public static let maxDelaySeconds = 300

    private let notes: any NoteStoring
    private let reminderTool: CreateReminderTool
    private let calendarTool: CreateCalendarEventTool
    private let openURL: URLOpener?
    private let startTimer: TimerStarter?
    private let callWebhook: WebhookCaller?
    private let sleep: Sleeper
    private let capture: Capturer?
    private let confirm: Confirmer?

    public init(
        notes: any NoteStoring,
        openURL: URLOpener? = nil,
        startTimer: TimerStarter? = nil,
        callWebhook: WebhookCaller? = nil,
        sleep: Sleeper? = nil,
        capture: Capturer? = nil,
        confirm: Confirmer? = nil,
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
        self.capture = capture
        self.confirm = confirm
        self.reminderTool = reminderTool
        self.calendarTool = calendarTool
    }

    public func run(_ skill: Skill) async -> SkillRunResult {
        var result = SkillRunResult()
        var variables: [String: String] = [:]
        for step in skill.steps {
            let resolved = interpolate(step, variables: variables)
            if let condition = resolved.condition {
                let value = variables[condition.variable] ?? ""
                if value != condition.equals {
                    result.summaryLines.append("skipped \(resolved.kind.rawValue) (condition)")
                    continue
                }
            }
            if resolved.requiresConfirmation == true {
                let allowed = await confirm?(
                    "Allow skill step?",
                    "\(skill.name): \(resolved.kind.rawValue) — \(resolved.text.isEmpty ? (resolved.url ?? "continue") : resolved.text)"
                ) ?? false
                if !allowed {
                    result.summaryLines.append("skipped \(resolved.kind.rawValue) (denied)")
                    continue
                }
            }

            let attempts = max(1, resolved.retryPolicy?.maxAttempts ?? 1)
            let delay = resolved.retryPolicy?.delaySeconds ?? 0
            var lastOK = false
            var output: String?
            for attempt in 1...attempts {
                let outcome = await execute(resolved, into: &result)
                lastOK = outcome.ok
                output = outcome.output
                if lastOK { break }
                if attempt < attempts, delay > 0 {
                    await sleep(TimeInterval(delay))
                }
            }
            if let name = resolved.outputVariable, !name.isEmpty {
                variables[name] = output ?? (lastOK ? "ok" : "fail")
            }
        }
        // Re-interpolate say/freeform with final variables for any leftover templates
        // already stored as prose during execute — templates in those kinds are
        // interpolated up front via `resolved`.
        _ = variables
        return result
    }

    // MARK: - Execution

    private struct StepOutcome {
        var ok: Bool
        var output: String?
    }

    private func execute(_ step: SkillStep, into result: inout SkillRunResult) async -> StepOutcome {
        switch step.kind {
        case .reminder:
            return await runReminder(step, into: &result)
        case .calendarEvent:
            return await runCalendar(step, into: &result)
        case .note:
            return await runNote(step, into: &result)
        case .openURL:
            return await runOpenURL(step, into: &result)
        case .timer:
            return await runTimer(step, into: &result)
        case .webhook:
            return await runWebhook(step, into: &result)
        case .delay:
            return await runDelay(step, into: &result)
        case .say:
            if !step.text.isEmpty { result.sayLines.append(step.text) }
            return StepOutcome(ok: true, output: step.text)
        case .freeform:
            if !step.text.isEmpty { result.freeform.append(step.text) }
            return StepOutcome(ok: true, output: step.text)
        case .capture:
            return await runCapture(step, into: &result)
        }
    }

    private func interpolate(_ step: SkillStep, variables: [String: String]) -> SkillStep {
        var copy = step
        copy.text = Self.expand(step.text, variables: variables)
        copy.url = step.url.map { Self.expand($0, variables: variables) }
        copy.dateISO = step.dateISO.map { Self.expand($0, variables: variables) }
        return copy
    }

    /// Replaces `{{name}}` placeholders with variable values (missing → empty).
    static func expand(_ template: String, variables: [String: String]) -> String {
        guard template.contains("{{") else { return template }
        var out = template
        for (key, value) in variables {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        // Clear unresolved placeholders so notes don't keep raw braces.
        if let regex = try? NSRegularExpression(pattern: #"\{\{[^}]+\}\}"#) {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "")
        }
        return out
    }

    // MARK: - Deterministic steps

    private func runReminder(_ step: SkillStep, into result: inout SkillRunResult) async -> StepOutcome {
        guard !step.text.isEmpty else { return StepOutcome(ok: false) }
        var args: [String: Any] = ["title": step.text]
        if let due = step.dateISO { args["dueISO8601"] = due }
        if let json = try? JSONSerialization.data(withJSONObject: args),
           (try? await reminderTool.invoke(argumentsJSON: String(decoding: json, as: UTF8.self))) != nil {
            result.summaryLines.append("set a reminder to \(step.text)")
            return StepOutcome(ok: true, output: step.text)
        }
        result.summaryLines.append("couldn't set the reminder to \(step.text)")
        return StepOutcome(ok: false)
    }

    private func runCalendar(_ step: SkillStep, into result: inout SkillRunResult) async -> StepOutcome {
        guard !step.text.isEmpty, let start = step.dateISO else { return StepOutcome(ok: false) }
        var args: [String: Any] = ["title": step.text, "startISO8601": start]
        if let mins = step.durationMinutes { args["durationMinutes"] = mins }
        if let json = try? JSONSerialization.data(withJSONObject: args),
           (try? await calendarTool.invoke(argumentsJSON: String(decoding: json, as: UTF8.self))) != nil {
            result.summaryLines.append("added \(step.text) to your calendar")
            return StepOutcome(ok: true, output: step.text)
        }
        result.summaryLines.append("couldn't add \(step.text) to your calendar")
        return StepOutcome(ok: false)
    }

    private func runNote(_ step: SkillStep, into result: inout SkillRunResult) async -> StepOutcome {
        guard !step.text.isEmpty else { return StepOutcome(ok: false) }
        await notes.save(step.text)
        result.summaryLines.append("saved a note")
        return StepOutcome(ok: true, output: step.text)
    }

    private func runOpenURL(_ step: SkillStep, into result: inout SkillRunResult) async -> StepOutcome {
        guard let raw = step.url, let url = URL(string: raw) else { return StepOutcome(ok: false) }
        if let openURL, await openURL(url) {
            result.summaryLines.append("opened \(raw)")
            return StepOutcome(ok: true, output: raw)
        }
        result.summaryLines.append("couldn't open \(raw)")
        return StepOutcome(ok: false)
    }

    private func runTimer(_ step: SkillStep, into result: inout SkillRunResult) async -> StepOutcome {
        guard let seconds = step.seconds, seconds > 0 else { return StepOutcome(ok: false) }
        let label = step.text.isEmpty ? "Timer" : step.text
        if let startTimer, await startTimer(seconds, label) {
            result.summaryLines.append("started a \(seconds)-second timer")
            return StepOutcome(ok: true, output: "\(seconds)")
        }
        result.summaryLines.append("couldn't start the timer")
        return StepOutcome(ok: false)
    }

    private func runWebhook(_ step: SkillStep, into result: inout SkillRunResult) async -> StepOutcome {
        guard let raw = step.url, let url = URL(string: raw) else { return StepOutcome(ok: false) }
        let method = (step.httpMethod ?? "GET").uppercased()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if method != "GET", !step.text.isEmpty {
            request.httpBody = Data(step.text.utf8)
            let trimmed = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isJSON = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
            request.setValue(isJSON ? "application/json" : "text/plain", forHTTPHeaderField: "Content-Type")
        }
        if let callWebhook, await callWebhook(request) {
            result.summaryLines.append("called the webhook")
            return StepOutcome(ok: true, output: "ok")
        }
        result.summaryLines.append("couldn't reach the webhook")
        return StepOutcome(ok: false, output: "fail")
    }

    private func runDelay(_ step: SkillStep, into result: inout SkillRunResult) async -> StepOutcome {
        guard let seconds = step.seconds, seconds > 0 else { return StepOutcome(ok: false) }
        let capped = min(seconds, Self.maxDelaySeconds)
        await sleep(TimeInterval(capped))
        result.summaryLines.append("waited \(capped) second\(capped == 1 ? "" : "s")")
        return StepOutcome(ok: true, output: "\(capped)")
    }

    private func runCapture(_ step: SkillStep, into result: inout SkillRunResult) async -> StepOutcome {
        guard let capture else { return StepOutcome(ok: false) }
        let text = await capture(step.text)
        if let text, !text.isEmpty {
            result.summaryLines.append("captured what you're looking at")
            let label = step.text.isEmpty ? "" : " (\(step.text))"
            result.freeform.append("Text captured from the glasses camera\(label):\n\(text)")
            return StepOutcome(ok: true, output: text)
        }
        result.summaryLines.append("captured an image but found no readable text")
        return StepOutcome(ok: false, output: "")
    }
}
