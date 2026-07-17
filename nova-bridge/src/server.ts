import express, { type Request, type Response, type NextFunction } from "express";
import { spawn } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";

/**
 * Nova Bridge — implements the wire contract the Nova iOS app's `NovaBridgeClient`
 * expects (all JSON, bearer-authenticated):
 *   POST /claude-code     { prompt, cwd? }
 *   POST /cursor/command  { command, sessionId? }
 *   GET  /cursor/sessions
 *   GET  /health          (unauthenticated liveness check)
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
        sessionId: (agent as { agentId?: string }).agentId ?? sessionId,
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
