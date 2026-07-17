import express, { type Request, type Response, type NextFunction } from "express";
import { spawn } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import {
  formatSse,
  normalizeHistoryMessage,
  normalizeSdkMessage,
  type CodingEvent,
} from "./cursor-stream.js";

/**
 * Nova Bridge — implements the wire contract the Nova iOS app's `NovaBridgeClient`
 * expects (all JSON, bearer-authenticated):
 *   POST /claude-code              { prompt, cwd? }
 *   POST /cursor/command           { command, sessionId? }  (blocking; prefer /cursor/runs)
 *   POST /cursor/runs              { command, sessionId?, cwd? }  → SSE stream
 *   POST /cursor/runs/:runId/cancel
 *   GET  /cursor/sessions
 *   GET  /cursor/sessions/:id/messages
 *   GET  /health                   (unauthenticated liveness check)
 */

// --- Minimal .env loader (no dependency) -----------------------------------
function loadEnv(): void {
  const path = resolve(process.cwd(), ".env");
  if (!existsSync(path)) return;
  for (const raw of readFileSync(path, "utf8").split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (process.env[key] === undefined) process.env[key] = value;
  }
}
loadEnv();

const PORT = Number(process.env.PORT ?? 8787);
const TOKEN = process.env.NOVA_BRIDGE_TOKEN ?? "";
const CURSOR_API_KEY = process.env.CURSOR_API_KEY ?? "";
const CURSOR_MODEL = process.env.CURSOR_MODEL ?? "composer-2.5";
const DEFAULT_CWD = process.env.NOVA_BRIDGE_WORKDIR || process.cwd();
const CLAUDE_BIN = process.env.CLAUDE_BIN || "claude";
const CLAUDE_ARGS = (process.env.CLAUDE_ARGS ?? "").trim();
const CLAUDE_TIMEOUT_MS = Number(process.env.CLAUDE_TIMEOUT_MS ?? 600_000);

const app = express();
app.use(express.json({ limit: "1mb" }));

// --- Auth -------------------------------------------------------------------
function requireAuth(req: Request, res: Response, next: NextFunction): void {
  if (!TOKEN) {
    res.status(500).json({ ok: false, error: "server_missing_token" });
    return;
  }
  const header = req.get("authorization") ?? "";
  const provided = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (provided !== TOKEN) {
    res.status(401).json({ ok: false, error: "unauthorized" });
    return;
  }
  next();
}

// --- Health (no auth) -------------------------------------------------------
app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    service: "nova-bridge",
    cursorConfigured: CURSOR_API_KEY.length > 0,
    defaultCwd: DEFAULT_CWD,
  });
});

// --- Claude Code ------------------------------------------------------------
app.post("/claude-code", requireAuth, async (req, res) => {
  const prompt = String(req.body?.prompt ?? "").trim();
  const cwd = String(req.body?.cwd ?? "").trim() || DEFAULT_CWD;
  if (!prompt) {
    res.status(400).json({ ok: false, error: "missing_prompt" });
    return;
  }
  try {
    const result = await runClaude(prompt, cwd);
    res.json({
      ok: result.code === 0,
      exitCode: result.code,
      result: result.stdout.trim(),
      ...(result.stderr.trim() ? { stderr: result.stderr.trim() } : {}),
    });
  } catch (err) {
    res.status(500).json({ ok: false, error: describe(err) });
  }
});

function runClaude(
  prompt: string,
  cwd: string,
): Promise<{ code: number; stdout: string; stderr: string }> {
  const extra = CLAUDE_ARGS ? CLAUDE_ARGS.split(/\s+/) : [];
  const args = ["-p", prompt, ...extra];
  return new Promise((resolvePromise, rejectPromise) => {
    let stdout = "";
    let stderr = "";
    const child = spawn(CLAUDE_BIN, args, {
      cwd,
      shell: process.platform === "win32",
      env: process.env,
    });
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      rejectPromise(new Error(`claude_timeout_after_${CLAUDE_TIMEOUT_MS}ms`));
    }, CLAUDE_TIMEOUT_MS);

    child.stdout.on("data", (d) => (stdout += d.toString()));
    child.stderr.on("data", (d) => (stderr += d.toString()));
    child.on("error", (e) => {
      clearTimeout(timer);
      rejectPromise(
        (e as NodeJS.ErrnoException).code === "ENOENT"
          ? new Error(`claude_cli_not_found (${CLAUDE_BIN})`)
          : e,
      );
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolvePromise({ code: code ?? -1, stdout, stderr });
    });
  });
}

// --- Cursor (via @cursor/sdk) ----------------------------------------------

/** In-flight runs keyed by runId for best-effort cancel. */
const activeRuns = new Map<
  string,
  { cancel: () => Promise<void>; agentId: string }
>();

app.post("/cursor/command", requireAuth, async (req, res) => {
  const command = String(req.body?.command ?? "").trim();
  const sessionId = String(req.body?.sessionId ?? "").trim();
  const cwd = String(req.body?.cwd ?? "").trim() || DEFAULT_CWD;
  if (!command) {
    res.status(400).json({ ok: false, error: "missing_command" });
    return;
  }
  if (!CURSOR_API_KEY) {
    res.status(500).json({ ok: false, error: "cursor_api_key_missing" });
    return;
  }
  try {
    const { Agent } = await import("@cursor/sdk");
    const agent = sessionId
      ? await Agent.resume(sessionId, { apiKey: CURSOR_API_KEY })
      : await Agent.create({
          apiKey: CURSOR_API_KEY,
          model: { id: CURSOR_MODEL },
          local: { cwd },
        });
    try {
      const run = await agent.send(command);
      const result = await run.wait();
      res.json({
        ok: result.status === "finished",
        sessionId: agent.agentId ?? sessionId,
        status: result.status,
        result: result.result ?? "",
      });
    } finally {
      await disposeAgent(agent);
    }
  } catch (err) {
    res.status(500).json({ ok: false, error: describe(err) });
  }
});

/** Streaming run for the Coding tab. Prefer this over /cursor/command. */
app.post("/cursor/runs", requireAuth, async (req, res) => {
  const command = String(req.body?.command ?? "").trim();
  const sessionId = String(req.body?.sessionId ?? "").trim();
  const cwd = String(req.body?.cwd ?? "").trim() || DEFAULT_CWD;
  if (!command) {
    res.status(400).json({ ok: false, error: "missing_command" });
    return;
  }
  if (!CURSOR_API_KEY) {
    res.status(500).json({ ok: false, error: "cursor_api_key_missing" });
    return;
  }

  res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
  res.setHeader("Cache-Control", "no-cache, no-transform");
  res.setHeader("Connection", "keep-alive");
  res.setHeader("X-Accel-Buffering", "no");
  if (typeof res.flushHeaders === "function") res.flushHeaders();

  const write = (event: CodingEvent): void => {
    if (res.writableEnded) return;
    res.write(formatSse(event));
  };

  let agent: Awaited<ReturnType<typeof import("@cursor/sdk").Agent.create>> | null =
    null;
  let runId = "";
  let resolvedSessionId = sessionId;

  try {
    const { Agent } = await import("@cursor/sdk");
    agent = sessionId
      ? await Agent.resume(sessionId, { apiKey: CURSOR_API_KEY })
      : await Agent.create({
          apiKey: CURSOR_API_KEY,
          model: { id: CURSOR_MODEL },
          local: { cwd },
        });
    resolvedSessionId = agent.agentId;
    write({ type: "status", status: "CREATING", sessionId: resolvedSessionId });

    const run = await agent.send(command);
    runId = run.id;
    activeRuns.set(runId, {
      agentId: resolvedSessionId,
      cancel: () => run.cancel(),
    });
    write({
      type: "status",
      status: "RUNNING",
      runId,
      sessionId: resolvedSessionId,
    });

    for await (const msg of run.stream()) {
      for (const event of normalizeSdkMessage(msg)) write(event);
    }

    const result = await run.wait();
    write({
      type: "done",
      sessionId: resolvedSessionId,
      runId,
      status: result.status,
      result: result.result ?? "",
    });
  } catch (err) {
    write({ type: "error", error: describe(err) });
    if (resolvedSessionId || runId) {
      write({
        type: "done",
        sessionId: resolvedSessionId || sessionId,
        runId: runId || "unknown",
        status: "error",
        result: "",
      });
    }
  } finally {
    if (runId) activeRuns.delete(runId);
    if (agent) await disposeAgent(agent);
    if (!res.writableEnded) res.end();
  }
});

app.post("/cursor/runs/:runId/cancel", requireAuth, async (req, res) => {
  const runId = String(req.params.runId ?? "").trim();
  if (!runId) {
    res.status(400).json({ ok: false, error: "missing_run_id" });
    return;
  }
  const tracked = activeRuns.get(runId);
  if (tracked) {
    try {
      await tracked.cancel();
      res.json({ ok: true, runId, cancelled: true, source: "active" });
      return;
    } catch (err) {
      res.status(500).json({ ok: false, error: describe(err) });
      return;
    }
  }
  if (!CURSOR_API_KEY) {
    res.status(404).json({ ok: false, error: "run_not_found" });
    return;
  }
  try {
    const { Agent } = await import("@cursor/sdk");
    await Agent.cancelRun(runId, {
      runtime: "local",
      cwd: DEFAULT_CWD,
    });
    res.json({ ok: true, runId, cancelled: true, source: "sdk" });
  } catch (err) {
    res.status(500).json({ ok: false, error: describe(err) });
  }
});

app.get("/cursor/sessions", requireAuth, async (_req, res) => {
  if (!CURSOR_API_KEY) {
    res.status(500).json({ ok: false, error: "cursor_api_key_missing" });
    return;
  }
  try {
    const { Agent } = await import("@cursor/sdk");
    const list = await Agent.list({
      runtime: "local",
      cwd: DEFAULT_CWD,
    });
    const sessions = list.items.map((a) => ({
      id: a.agentId,
      status: a.status,
      title: a.name,
      summary: a.summary,
      lastModified: a.lastModified,
    }));
    res.json({ ok: true, count: sessions.length, sessions });
  } catch (err) {
    res.status(500).json({ ok: false, error: describe(err) });
  }
});

app.get("/cursor/sessions/:id/messages", requireAuth, async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  if (!id) {
    res.status(400).json({ ok: false, error: "missing_session_id" });
    return;
  }
  if (!CURSOR_API_KEY) {
    res.status(500).json({ ok: false, error: "cursor_api_key_missing" });
    return;
  }
  try {
    const { Agent } = await import("@cursor/sdk");
    const raw = await Agent.messages.list(id, {
      runtime: "local",
      cwd: DEFAULT_CWD,
      limit: Number(req.query.limit ?? 200) || 200,
    });
    const messages = raw
      .map(normalizeHistoryMessage)
      .filter((m): m is NonNullable<typeof m> => m !== null);
    res.json({ ok: true, sessionId: id, count: messages.length, messages });
  } catch (err) {
    res.status(500).json({ ok: false, error: describe(err) });
  }
});

async function disposeAgent(agent: unknown): Promise<void> {
  const disposer = (agent as Record<symbol, unknown>)[Symbol.asyncDispose];
  if (typeof disposer === "function") {
    try {
      await (disposer as () => Promise<void>).call(agent);
    } catch {
      /* best effort */
    }
  }
}

function describe(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

app.listen(PORT, () => {
  console.log(`Nova Bridge listening on http://0.0.0.0:${PORT}`);
  console.log(`  token set:       ${TOKEN ? "yes" : "NO (set NOVA_BRIDGE_TOKEN)"}`);
  console.log(`  cursor api key:  ${CURSOR_API_KEY ? "yes" : "no"}`);
  console.log(`  default cwd:     ${DEFAULT_CWD}`);
});
