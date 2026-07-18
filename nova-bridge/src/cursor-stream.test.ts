/**
 * Tiny smoke checks for SSE event normalization (no SDK needed).
 * Run: npx tsx src/cursor-stream.test.ts
 */
import {
  formatSse,
  normalizeConversationStep,
  normalizeHistoryMessage,
  normalizeInteractionUpdate,
  normalizeSdkMessage,
} from "./cursor-stream.js";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

const assistant = normalizeSdkMessage({
  type: "assistant",
  message: { role: "assistant", content: [{ type: "text", text: "Hi" }] },
});
assert(assistant.length === 1 && assistant[0].type === "assistant_delta", "assistant_delta");
assert(assistant[0].type === "assistant_delta" && assistant[0].text === "Hi", "assistant text");

const emptyThinking = normalizeSdkMessage({ type: "thinking", text: "", agent_id: "a", run_id: "r" });
assert(emptyThinking[0]?.type === "activity", "empty thinking → activity");

const toolStart = normalizeSdkMessage({
  type: "tool_call",
  name: "edit",
  status: "running",
  args: { path: "a.swift" },
});
assert(toolStart.some((e) => e.type === "tool_start"), "tool_start");
assert(
  toolStart.some((e) => e.type === "tool_start" && e.path === "a.swift"),
  "tool path",
);

const toolEnd = normalizeSdkMessage({
  type: "tool_call",
  name: "edit",
  status: "completed",
  args: { path: "a.swift" },
  result: { diffString: "--- a\n+++ b\n@@\n-x\n+y\n" },
});
assert(toolEnd.some((e) => e.type === "tool_end"), "tool_end");
assert(
  toolEnd.some((e) => e.type === "tool_end" && e.diff?.includes("@@")),
  "diff",
);

const hist = normalizeHistoryMessage({
  type: "user",
  uuid: "u1",
  message: { role: "user", content: [{ type: "text", text: "fix" }] },
});
assert(hist?.role === "user" && hist.text === "fix", "history user");

const sse = formatSse({ type: "status", status: "RUNNING" });
assert(sse.startsWith("data: ") && sse.endsWith("\n\n"), "sse format");

const thinkingDelta = normalizeInteractionUpdate({ type: "thinking-delta", text: "hmm" });
assert(
  thinkingDelta[0]?.type === "thinking_delta" && thinkingDelta[0].text === "hmm",
  "onDelta thinking",
);

const textDelta = normalizeInteractionUpdate({ type: "text-delta", text: "Hi" });
assert(textDelta[0]?.type === "assistant_delta" && textDelta[0].text === "Hi", "onDelta text");

const toolDelta = normalizeInteractionUpdate({
  type: "tool-call-started",
  callId: "c1",
  modelCallId: "m1",
  toolCall: { type: "read", args: { path: "foo.ts" } },
});
assert(toolDelta.some((e) => e.type === "tool_start" && e.name === "read"), "onDelta tool");

const step = normalizeConversationStep({ type: "assistantMessage", message: { text: "done" } });
assert(step[0]?.type === "activity", "onStep activity");

const usage = normalizeSdkMessage({
  type: "usage",
  usage: { totalTokens: 42 },
});
assert(usage[0]?.type === "activity" && usage[0].phase === "usage", "usage activity");

console.log("cursor-stream.test.ts: ok");
