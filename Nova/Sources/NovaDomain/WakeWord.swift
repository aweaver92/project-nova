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

    private func classify(command: String, full: String) -> WakeIntent {
        let haystack = command.isEmpty ? full : command
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
}
