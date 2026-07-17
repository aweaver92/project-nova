import Foundation

/// Wake-word + intent detection over a completed user transcript.
///
/// Nova only acts when addressed by name ("Nova ..."). A follow-on phrase such
/// as "what's this?" routes to the vision path instead of a plain spoken reply.
/// Pure and deterministic — mirrors the TypeScript `WakeWordDetector` in nova-sim.
public enum WakeIntent: Equatable, Sendable {
    case ignore
    case converse(command: String)
    case vision(prompt: String)
    /// "Nova, stop": halt any in-progress speech and stop treating follow-ups as
    /// addressed to Nova until the wake word is spoken again.
    case stop
}

public struct WakeWordDetector: Sendable {
    public static let defaultVisionPhrases: [String] = [
        "what's this",
        "what is this",
        "what's that",
        "what is that",
        "what am i looking at",
        "what do you see",
        "look at this",
        "describe this",
        "describe what i'm seeing",
    ]

    private static let defaultVisionPrompt = "What am I looking at? Be concise."

    /// Exact commands (after the wake word / normalization) that mean "stop and
    /// stand down". Matched exactly so requests like "stop the recording" still
    /// route to the model/tools instead of being swallowed here.
    private static let stopCommands: Set<String> = [
        "stop",
        "stop talking",
        "stop it",
        "stop listening",
        "be quiet",
        "quiet",
        "shush",
        "hush",
        "shut up",
        "never mind",
        "nevermind",
        "thats enough",
        "that is enough",
        "thats all",
        "that is all",
    ]

    private let wakeTokens: [String]
    private let visionPhrases: [String]

    public init(wakeWord: String = "Nova", visionPhrases: [String] = WakeWordDetector.defaultVisionPhrases) {
        self.wakeTokens = Self.normalize(wakeWord).split(separator: " ").map(String.init)
        self.visionPhrases = visionPhrases
            .map(Self.normalize)
            .filter { !$0.isEmpty }
    }

    public func detect(_ transcript: String) -> WakeIntent {
        let full = Self.normalize(transcript)
        if full.isEmpty { return .ignore }
        let words = full.split(separator: " ").map(String.init)

        guard !wakeTokens.isEmpty else {
            return classify(command: full, full: full)
        }
        guard let start = Self.firstIndex(of: wakeTokens, in: words) else {
            return .ignore
        }
        let command = words[(start + wakeTokens.count)...].joined(separator: " ")
        return classify(command: command, full: full)
    }

    /// Classifies an utterance as though Nova is already being addressed, i.e.
    /// without requiring the wake word. Used by the orchestrator's listening-mode
    /// grace window so follow-up turns don't need "Nova" repeated. Returns
    /// `.ignore` only for empty/blank input.
    public func detectAssumingAddressed(_ transcript: String) -> WakeIntent {
        let full = Self.normalize(transcript)
        if full.isEmpty { return .ignore }
        return classify(command: full, full: full)
    }

    private func classify(command: String, full: String) -> WakeIntent {
        let haystack = command.isEmpty ? full : command
        if Self.stopCommands.contains(haystack) {
            return .stop
        }
        if visionPhrases.contains(where: { haystack.contains($0) }) {
            return .vision(prompt: command.isEmpty ? Self.defaultVisionPrompt : command)
        }
        return .converse(command: command)
    }

    /// lowercase, drop apostrophes ("what's" → "whats"), punctuation → space.
    private static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.lowercased() {
            if ch == "'" || ch == "\u{2019}" { continue }
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") {
                out.append(ch)
            } else {
                out.append(" ")
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    /// Index of the first occurrence of `needle` as a contiguous subsequence.
    private static func firstIndex(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<(i + needle.count)]) == needle {
            return i
        }
        return nil
    }

    /// Shared normalization so `AgentDirector` matches the detector 1:1.
    static func normalizeText(_ s: String) -> String { normalize(s) }
    static func indexOf(_ needle: [String], in haystack: [String]) -> Int? { firstIndex(of: needle, in: haystack) }
}

/// A master-level control command parsed from a completed utterance.
public enum AgentControlIntent: Equatable, Sendable {
    case none
    /// Hand off to another specialist (or back to a named agent).
    case switchTo(agentId: UUID)
    /// End the sub-agent conversation and return to the master (Nova).
    case endConversation
}

/// Detects the master's switching/ending commands ("Nova, let me talk to
/// Claude" / "Nova, end the conversation"). Requires the master wake word so a
/// sub-agent can never switch specialists — only Nova can. Pure + deterministic.
public struct AgentDirector: Sendable {
    private struct Entry: Sendable { let id: UUID; let tokenSets: [[String]] }

    private let masterTokens: [String]
    private let entries: [Entry]

    private static let switchTriggers: [[String]] = [
        ["let", "me", "talk", "to"],
        ["let", "me", "speak", "to"],
        ["let", "me", "speak", "with"],
        ["let", "me", "chat", "with"],
        ["i", "want", "to", "talk", "to"],
        ["i", "want", "to", "speak", "to"],
        ["i", "wanna", "talk", "to"],
        ["connect", "me", "to"],
        ["connect", "me", "with"],
        ["put", "me", "on", "with"],
        ["switch", "to"],
        ["switch", "me", "to"],
        ["bring", "in"],
        ["talk", "to"],
        ["speak", "to"],
        ["speak", "with"],
        ["chat", "with"],
    ].map { $0 }

    private static let endPhrases: [[String]] = [
        ["end", "the", "conversation"],
        ["end", "conversation"],
        ["end", "the", "session"],
        ["go", "back", "to", "nova"],
        ["back", "to", "nova"],
        ["return", "to", "nova"],
        ["switch", "back", "to", "nova"],
        ["that", "is", "all", "nova"],
        ["thats", "all", "nova"],
        ["dismiss", "the", "agent"],
    ]

    public init(master: Agent, agents: [Agent]) {
        self.masterTokens = WakeWordDetector.normalizeText(master.wakeWord)
            .split(separator: " ").map(String.init)
        self.entries = agents.map { agent in
            var sets: [[String]] = []
            let name = WakeWordDetector.normalizeText(agent.name).split(separator: " ").map(String.init)
            let wake = WakeWordDetector.normalizeText(agent.wakeWord).split(separator: " ").map(String.init)
            if !name.isEmpty { sets.append(name) }
            if !wake.isEmpty, wake != name { sets.append(wake) }
            return Entry(id: agent.id, tokenSets: sets)
        }
    }

    public func control(for transcript: String) -> AgentControlIntent {
        let words = WakeWordDetector.normalizeText(transcript).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return .none }
        // Only the master ("Nova") can drive switching/ending.
        guard !masterTokens.isEmpty, WakeWordDetector.indexOf(masterTokens, in: words) != nil else {
            return .none
        }

        // A switch requires a trigger phrase followed by a known agent name.
        for trigger in Self.switchTriggers {
            guard let start = WakeWordDetector.indexOf(trigger, in: words) else { continue }
            let remainder = Array(words[(start + trigger.count)...])
            if let id = matchAgent(in: remainder) {
                return .switchTo(agentId: id)
            }
        }

        for phrase in Self.endPhrases where WakeWordDetector.indexOf(phrase, in: words) != nil {
            return .endConversation
        }

        return .none
    }

    private func matchAgent(in words: [String]) -> UUID? {
        guard !words.isEmpty else { return nil }
        var best: (id: UUID, at: Int)?
        for entry in entries {
            for tokens in entry.tokenSets {
                if let at = WakeWordDetector.indexOf(tokens, in: words) {
                    if best == nil || at < best!.at { best = (entry.id, at) }
                }
            }
        }
        return best?.id
    }
}
