/**
 * Normalize @cursor/sdk stream messages into a stable SSE envelope for the
 * Nova iOS Coding tab. Keep this independent of raw SDK message layouts.
 */

export type CodingEvent =
  | { type: "assistant_delta"; text: string }
  | { type: "thinking_delta"; text: string }
  | { type: "tool_start"; name: string; summary?: string; path?: string }
  | { type: "tool_end"; name: string; summary?: string; path?: string; diff?: string }
  | { type: "status"; status: string; runId?: string; sessionId?: string }
  | { type: "error"; error: string }
  | {
      type: "done";
      sessionId: string;
      runId: string;
      status: string;
      result: string;
    };

type Loose = Record<string, unknown>;

function asRecord(value: unknown): Loose | null {
  return value !== null && typeof value === "object" ? (value as Loose) : null;
}

function textFromContent(content: unknown): string {
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const block of content) {
    const b = asRecord(block);
    if (!b) continue;
    if (b.type === "text" && typeof b.text === "string") parts.push(b.text);
  }
  return parts.join("");
}

function pathFromArgs(args: unknown): string | undefined {
  const a = asRecord(args);
  if (!a) return undefined;
  for (const key of ["path", "file_path", "filePath", "target_file", "targetFile"]) {
    const v = a[key];
    if (typeof v === "string" && v.trim()) return v;
  }
  return undefined;
}

function diffFromResult(result: unknown): string | undefined {
  if (typeof result === "string") {
    // Heuristic: unified diffs often start with ---/+++ or contain @@ hunks.
    if (result.includes("\n@@") || result.startsWith("--- ") || result.includes("diff --git")) {
      return result;
    }
    return undefined;
  }
  const r = asRecord(result);
  if (!r) return undefined;
  for (const key of ["diffString", "diff", "patch"]) {
    const v = r[key];
    if (typeof v === "string" && v.trim()) return v;
  }
  return undefined;
}

function summaryFrom(value: unknown, fallback?: string): string | undefined {
  if (typeof value === "string" && value.trim()) {
    return value.length > 240 ? `${value.slice(0, 237)}…` : value;
  }
  const r = asRecord(value);
  if (r) {
    for (const key of ["summary", "message", "output", "stdout"]) {
      const v = r[key];
      if (typeof v === "string" && v.trim()) {
        return v.length > 240 ? `${v.slice(0, 237)}…` : v;
      }
    }
  }
  return fallback;
}

/** Map one SDKMessage (or similar) into zero-or-more CodingEvents. */
export function normalizeSdkMessage(msg: unknown): CodingEvent[] {
  const m = asRecord(msg);
  if (!m || typeof m.type !== "string") return [];

  switch (m.type) {
    case "assistant": {
      const message = asRecord(m.message);
      const text = textFromContent(message?.content);
      return text ? [{ type: "assistant_delta", text }] : [];
    }
    case "thinking": {
      const text = typeof m.text === "string" ? m.text : "";
      return text ? [{ type: "thinking_delta", text }] : [];
    }
    case "tool_call": {
      const name = typeof m.name === "string" ? m.name : "tool";
      const status = typeof m.status === "string" ? m.status : "running";
      const path = pathFromArgs(m.args);
      if (status === "running") {
        return [
          {
            type: "tool_start",
            name,
            summary: summaryFrom(m.args),
            ...(path ? { path } : {}),
          },
        ];
      }
      return [
        {
          type: "tool_end",
          name,
          summary: summaryFrom(m.result, status === "error" ? "error" : undefined),
          ...(path ? { path } : {}),
          ...(diffFromResult(m.result) ? { diff: diffFromResult(m.result) } : {}),
        },
      ];
    }
    case "status": {
      const status = typeof m.status === "string" ? m.status : "UNKNOWN";
      return [{ type: "status", status }];
    }
    default:
      return [];
  }
}

/** Normalize Agent.messages.list entries into simple transcript turns. */
export function normalizeHistoryMessage(msg: unknown): {
  role: "user" | "assistant";
  text: string;
  id?: string;
} | null {
  const m = asRecord(msg);
  if (!m) return null;
  const role = m.type === "user" || m.type === "assistant" ? m.type : null;
  if (!role) return null;
  const message = asRecord(m.message);
  let text = "";
  if (message) {
    text = textFromContent(message.content);
    if (!text && typeof message.content === "string") text = message.content;
  }
  if (!text && typeof m.message === "string") text = m.message;
  if (!text) return null;
  return {
    role,
    text,
    ...(typeof m.uuid === "string" ? { id: m.uuid } : {}),
  };
}

export function formatSse(event: CodingEvent): string {
  return `data: ${JSON.stringify(event)}\n\n`;
}
