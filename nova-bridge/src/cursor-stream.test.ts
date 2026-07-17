/**
 * Tiny smoke checks for SSE event normalization (no SDK needed).
 * Run: npx tsx src/cursor-stream.test.ts
 */
import {
  formatSse,
  normalizeHistoryMessage,
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

const toolStart = normalizeSdkMessage({
  type: "tool_call",
  name: "edit",
  status: "running",
  args: { path: "a.swift" },
});
assert(toolStart[0]?.type === "tool_start", "tool_start");
assert(toolStart[0]?.type === "tool_start" && toolStart[0].path === "a.swift", "tool path");

const toolEnd = normalizeSdkMessage({
  type: "tool_call",
  name: "edit",
  status: "completed",
  args: { path: "a.swift" },
  result: { diffString: "--- a\n+++ b\n@@\n-x\n+y\n" },
});
assert(toolEnd[0]?.type === "tool_end", "tool_end");
assert(toolEnd[0]?.type === "tool_end" && toolEnd[0].diff?.includes("@@"), "diff");

const hist = normalizeHistoryMessage({
  type: "user",
  uuid: "u1",
  message: { role: "user", content: [{ type: "text", text: "fix" }] },
});
assert(hist?.role === "user" && hist.text === "fix", "history user");

const sse = formatSse({ type: "status", status: "RUNNING" });
assert(sse.startsWith("data: ") && sse.endsWith("\n\n"), "sse format");

console.log("cursor-stream.test.ts: ok");
