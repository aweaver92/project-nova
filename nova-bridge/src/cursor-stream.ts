/**
 * Normalize @cursor/sdk stream messages / InteractionUpdates into a stable SSE
 * envelope for the Nova iOS Coding tab.
 */

export type CodingEvent =
  | { type: "assistant_delta"; text: string }
  | { type: "thinking_delta"; text: string }
  | { type: "tool_start"; name: string; summary?: string; path?: string }
  | { type: "tool_end"; name: string; summary?: string; path?: string; diff?: string }
  | {
      type: "activity";
      phase: string;
      text: string;
      detail?: string;
      done?: boolean;
    }
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
    for (const key of ["summary", "message", "output", "stdout", "command"]) {
      const v = r[key];
      if (typeof v === "string" && v.trim()) {
        return v.length > 240 ? `${v.slice(0, 237)}…` : v;
      }
    }
  }
  return fallback;
}

function toolCallFields(toolCall: unknown): {
  name: string;
  path?: string;
  summary?: string;
  diff?: string;
} {
  const t = asRecord(toolCall);
  if (!t) return { name: "tool" };
  const name =
    typeof t.type === "string" && t.type.trim()
      ? t.type
      : typeof t.name === "string" && t.name.trim()
        ? t.name
        : "tool";
  const args = t.args ?? t.arguments;
  const path = pathFromArgs(args);
  const summary =
    summaryFrom(args) ??
    (typeof (asRecord(args) as Loose | null)?.command === "string"
      ? String((args as Loose).command)
      : undefined);
  const result = t.result;
  const resultRec = asRecord(result);
  const resultValue = resultRec?.value ?? result;
  return {
    name,
    ...(path ? { path } : {}),
    ...(summary ? { summary } : {}),
    ...(diffFromResult(resultValue) || diffFromResult(result)
      ? { diff: diffFromResult(resultValue) ?? diffFromResult(result) }
      : {}),
  };
}

function activity(
  phase: string,
  text: string,
  detail?: string,
  done?: boolean,
): CodingEvent {
  return {
    type: "activity",
    phase,
    text,
    ...(detail ? { detail } : {}),
    ...(done !== undefined ? { done } : {}),
  };
}

/** Map one SDKMessage (or similar) into zero-or-more CodingEvents. */
export function normalizeSdkMessage(msg: unknown): CodingEvent[] {
  const m = asRecord(msg);
  if (!m || typeof m.type !== "string") return [];

  switch (m.type) {
    case "assistant": {
      const message = asRecord(m.message);
      let text = textFromContent(message?.content);
      if (!text && typeof message?.content === "string") text = message.content;
      if (!text && typeof m.text === "string") text = m.text;
      if (!text && typeof m.delta === "string") text = m.delta;
      return text ? [{ type: "assistant_delta", text }] : [];
    }
    case "thinking": {
      const text =
        typeof m.text === "string"
          ? m.text
          : typeof m.delta === "string"
            ? m.delta
            : "";
      if (text) return [{ type: "thinking_delta", text }];
      // Empty thinking placeholders still mean the agent is reasoning.
      const duration =
        typeof m.thinking_duration_ms === "number"
          ? `${Math.round(m.thinking_duration_ms)}ms`
          : undefined;
      return [
        activity(
          "thinking",
          duration ? `Thinking (${duration})` : "Thinking…",
          undefined,
          typeof m.thinking_duration_ms === "number",
        ),
      ];
    }
    case "text-delta":
    case "text_delta":
    case "assistant_delta": {
      const text =
        typeof m.text === "string"
          ? m.text
          : typeof m.delta === "string"
            ? m.delta
            : "";
      return text ? [{ type: "assistant_delta", text }] : [];
    }
    case "thinking-delta":
    case "thinking_delta": {
      const text =
        typeof m.text === "string"
          ? m.text
          : typeof m.delta === "string"
            ? m.delta
            : "";
      return text ? [{ type: "thinking_delta", text }] : [];
    }
    case "tool_call":
    case "tool-call-started":
    case "tool_call_started": {
      const name = typeof m.name === "string" ? m.name : "tool";
      const status = typeof m.status === "string" ? m.status : "running";
      const path = pathFromArgs(m.args ?? m.arguments);
      if (status === "running" || m.type !== "tool_call") {
        return [
          {
            type: "tool_start",
            name,
            summary: summaryFrom(m.args ?? m.arguments),
            ...(path ? { path } : {}),
          },
          activity(
            "tool",
            path ? `${name} · ${path}` : `Running ${name}`,
            summaryFrom(m.args ?? m.arguments),
            false,
          ),
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
        activity(
          "tool",
          path ? `${name} · ${path}` : `Finished ${name}`,
          summaryFrom(m.result, status === "error" ? "error" : undefined),
          true,
        ),
      ];
    }
    case "tool-call-completed":
    case "tool_call_completed": {
      const name = typeof m.name === "string" ? m.name : "tool";
      const path = pathFromArgs(m.args ?? m.arguments);
      return [
        {
          type: "tool_end",
          name,
          summary: summaryFrom(m.result),
          ...(path ? { path } : {}),
          ...(diffFromResult(m.result) ? { diff: diffFromResult(m.result) } : {}),
        },
        activity(
          "tool",
          path ? `${name} · ${path}` : `Finished ${name}`,
          summaryFrom(m.result),
          true,
        ),
      ];
    }
    case "status": {
      const status = typeof m.status === "string" ? m.status : "UNKNOWN";
      const message = typeof m.message === "string" ? m.message : undefined;
      return [
        { type: "status", status },
        activity("status", status, message, ["FINISHED", "ERROR", "CANCELLED", "EXPIRED"].includes(status)),
      ];
    }
    case "system": {
      const model = asRecord(m.model);
      const modelId = typeof model?.id === "string" ? model.id : undefined;
      return [activity("system", "Agent ready", modelId ?? (typeof m.subtype === "string" ? m.subtype : undefined))];
    }
    case "task": {
      const text =
        typeof m.text === "string" && m.text.trim()
          ? m.text
          : typeof m.status === "string"
            ? m.status
            : "Task update";
      return [activity("task", text, typeof m.status === "string" ? m.status : undefined)];
    }
    case "request": {
      return [activity("request", "Waiting for approval", typeof m.request_id === "string" ? m.request_id : undefined)];
    }
    case "usage": {
      const usage = asRecord(m.usage);
      const total =
        typeof usage?.totalTokens === "number"
          ? usage.totalTokens
          : typeof usage?.total_tokens === "number"
            ? usage.total_tokens
            : undefined;
      const detail =
        total !== undefined
          ? `${total} tokens`
          : usage
            ? JSON.stringify(usage).slice(0, 120)
            : undefined;
      return [activity("usage", "Token usage", detail, true)];
    }
    case "user":
      return [];
    default:
      return [];
  }
}

/** Map one InteractionUpdate from `send({ onDelta })` into CodingEvents. */
export function normalizeInteractionUpdate(update: unknown): CodingEvent[] {
  const u = asRecord(update);
  if (!u || typeof u.type !== "string") return [];

  switch (u.type) {
    case "text-delta": {
      const text = typeof u.text === "string" ? u.text : "";
      return text ? [{ type: "assistant_delta", text }] : [];
    }
    case "thinking-delta": {
      const text = typeof u.text === "string" ? u.text : "";
      if (text) return [{ type: "thinking_delta", text }];
      return [activity("thinking", "Thinking…")];
    }
    case "thinking-completed": {
      const ms =
        typeof u.thinkingDurationMs === "number"
          ? `${Math.round(u.thinkingDurationMs)}ms`
          : undefined;
      return [activity("thinking", ms ? `Thought for ${ms}` : "Thinking done", undefined, true)];
    }
    case "tool-call-started":
    case "partial-tool-call": {
      const fields = toolCallFields(u.toolCall);
      const started = u.type === "tool-call-started";
      const events: CodingEvent[] = [
        activity(
          "tool",
          fields.path ? `${fields.name} · ${fields.path}` : `Running ${fields.name}`,
          fields.summary,
          false,
        ),
      ];
      if (started) {
        events.unshift({
          type: "tool_start",
          name: fields.name,
          ...(fields.summary ? { summary: fields.summary } : {}),
          ...(fields.path ? { path: fields.path } : {}),
        });
      }
      return events;
    }
    case "tool-call-completed": {
      const fields = toolCallFields(u.toolCall);
      return [
        {
          type: "tool_end",
          name: fields.name,
          ...(fields.summary ? { summary: fields.summary } : {}),
          ...(fields.path ? { path: fields.path } : {}),
          ...(fields.diff ? { diff: fields.diff } : {}),
        },
        activity(
          "tool",
          fields.path ? `${fields.name} · ${fields.path}` : `Finished ${fields.name}`,
          fields.summary,
          true,
        ),
      ];
    }
    case "step-started": {
      const id = typeof u.stepId === "number" ? u.stepId : undefined;
      return [activity("step", id !== undefined ? `Step ${id}` : "Step started")];
    }
    case "step-completed": {
      const id = typeof u.stepId === "number" ? u.stepId : undefined;
      const ms =
        typeof u.stepDurationMs === "number"
          ? `${Math.round(u.stepDurationMs)}ms`
          : undefined;
      return [
        activity(
          "step",
          id !== undefined ? `Step ${id} done` : "Step done",
          ms,
          true,
        ),
      ];
    }
    case "turn-ended": {
      const usage = asRecord(u.usage);
      const detail = usage
        ? `in ${usage.inputTokens ?? "?"} / out ${usage.outputTokens ?? "?"}`
        : undefined;
      return [activity("turn", "Turn ended", detail, true)];
    }
    case "summary": {
      const text = typeof u.summary === "string" ? u.summary : "Summary";
      return [activity("summary", text)];
    }
    case "summary-started":
      return [activity("summary", "Summarizing…")];
    case "summary-completed":
      return [activity("summary", "Summary ready", undefined, true)];
    case "shell-output-delta":
      return [activity("shell", "Shell output…")];
    case "token-delta":
    case "user-message-appended":
      return [];
    default:
      return [];
  }
}

/** Light activity markers from `send({ onStep })` completed conversation steps. */
export function normalizeConversationStep(step: unknown): CodingEvent[] {
  const s = asRecord(step);
  if (!s || typeof s.type !== "string") return [];
  switch (s.type) {
    case "thinkingMessage":
      return [activity("thinking", "Thinking step complete", undefined, true)];
    case "toolCall": {
      const fields = toolCallFields(s.message ?? s.toolCall ?? s);
      return [
        activity(
          "tool",
          fields.path ? `${fields.name} · ${fields.path}` : fields.name,
          fields.summary,
          true,
        ),
      ];
    }
    case "assistantMessage":
      return [activity("assistant", "Assistant reply", undefined, true)];
    default:
      return [];
  }
}

/** Compact debug sample for unmapped payloads (no huge dumps). */
export function describeUnknownMessage(msg: unknown): string {
  const m = asRecord(msg);
  if (!m) return typeof msg;
  const keys = Object.keys(m).slice(0, 12).join(",");
  const type = typeof m.type === "string" ? m.type : "?";
  return `type=${type} keys=${keys}`;
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
