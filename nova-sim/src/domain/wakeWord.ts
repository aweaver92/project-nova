/**
 * Wake-word + intent detection over a completed user transcript.
 *
 * Nova only acts when addressed by name ("Nova ..."). A follow-on phrase like
 * "what's this?" routes to the vision path instead of a plain spoken reply.
 * Pure and deterministic so it can be unit-tested and shared 1:1 with the Swift
 * `WakeWordDetector`.
 */
export type WakeIntent =
  | { kind: "ignore" }
  | { kind: "converse"; command: string }
  | { kind: "vision"; prompt: string }
  // "Nova, stop": halt any in-progress speech and stop treating follow-ups as
  // addressed to Nova until the wake word is spoken again.
  | { kind: "stop" };

export const DEFAULT_VISION_PHRASES = [
  "what's this",
  "what is this",
  "what's that",
  "what is that",
  "what am i looking at",
  "what do you see",
  "look at this",
  "describe this",
  "describe what i'm seeing",
];

const DEFAULT_VISION_PROMPT = "What am I looking at? Be concise.";

/**
 * Exact commands (after the wake word / normalization) that mean "stop and
 * stand down". Matched exactly so requests like "stop the recording" still
 * route to the model/tools instead of being swallowed here.
 */
const STOP_COMMANDS = new Set([
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
]);

/** lowercase, drop apostrophes ("what's" → "whats"), punctuation → space. */
function normalize(s: string): string {
  return s
    .toLowerCase()
    .replace(/['\u2019]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export class WakeWordDetector {
  private readonly wake: string;
  private readonly visionPhrases: string[];

  constructor(wakeWord = "Nova", visionPhrases: string[] = DEFAULT_VISION_PHRASES) {
    this.wake = normalize(wakeWord);
    this.visionPhrases = visionPhrases.map(normalize).filter((p) => p.length > 0);
  }

  detect(transcript: string): WakeIntent {
    const norm = normalize(transcript);
    if (!norm) return { kind: "ignore" };

    // No wake word configured → always act on the utterance.
    if (this.wake) {
      const wakeRe = new RegExp(`\\b${escapeRegExp(this.wake)}\\b`);
      const match = wakeRe.exec(norm);
      if (!match) return { kind: "ignore" };
      const command = norm.slice(match.index + match[0].length).trim();
      return this.classify(command, norm);
    }
    return this.classify(norm, norm);
  }

  private classify(command: string, full: string): WakeIntent {
    const haystack = command.length ? command : full;
    if (STOP_COMMANDS.has(haystack)) {
      return { kind: "stop" };
    }
    if (this.visionPhrases.some((p) => haystack.includes(p))) {
      return {
        kind: "vision",
        prompt: command.length ? command : DEFAULT_VISION_PROMPT,
      };
    }
    return { kind: "converse", command };
  }
}
