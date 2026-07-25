import Foundation

/// Smoothing + visibility gate for amplitude-driven talking avatars.
public enum AssistantTalkMeter: Sendable {
    /// Attack/release envelope so chunky PCM peaks don’t flicker the mouth.
    public static func smooth(previous: Float, sample: Float, attack: Float = 0.55, release: Float = 0.18) -> Float {
        let s = max(0, min(1, sample))
        let p = max(0, min(1, previous))
        if s >= p {
            return p + (s - p) * attack
        }
        return p + (s - p) * release
    }

    /// True when the assistant turn is active and energy is audible enough to animate.
    public static func isVisiblyTalking(
        smoothedLevel: Float,
        assistantSpeaking: Bool,
        levelFloor: Float = 0.04
    ) -> Bool {
        assistantSpeaking && smoothedLevel >= levelFloor
    }
}
