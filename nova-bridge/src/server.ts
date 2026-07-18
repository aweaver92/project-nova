import express, { type Request, type Response, type NextFunction } from "express";
import { spawn } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import {
  describeUnknownMessage,
  formatSse,
  normalizeConversationStep,
  normalizeHistoryMessage,
  normalizeInteractionUpdate,
  normalizeSdkMessage,
  type CodingEvent,
} from "./cursor-stream.js";
import { bootstrapCursorRipgrep } from "./bootstrap-ripgrep.js";
import { PreviewService, previewUrl } from "./preview-service.js";
import { RepoError, RepoService, timingSafeTokenEqual } from "./repo-service.js";

/**
 * Nova Bridge — implements the wire contract the Nova iOS app's `NovaBridgeClient`
 * expects (all JSON, bearer-authenticated):
 *   POST /realtime/token           { model? }               → { value, expires_at }
 *   POST /claude-code              { prompt, repoId?, cwd? }
 *   POST /cursor/command           { command, sessionId?, repoId? }
 *   POST /cursor/runs              { command, sessionId?, repoId? }  → SSE stream
 *   POST /cursor/runs/:runId/cancel
 *   GET  /cursor/sessions
 *   GET  /cursor/sessions/:id/messages
 *   GET  /repos
 *   POST /repos/clone | /repos/create | /repos/select
 *   GET  /repos/:repoId/status | /diff | /files?path=
 *   POST /repos/:repoId/publish
 *   GET  /preview                  active previews
 *   POST /preview/start            { repoId, path? }  → LAN preview URL
 *   POST /preview/stop             { repoId }
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

// Must run before any Agent.create/resume — SDK scans gitignore via ripgrep.
const RIPGREP_PATH = bootstrapCursorRipgrep();

const PORT = Number(process.env.PORT ?? 8787);
const TOKEN = process.env.NOVA_BRIDGE_TOKEN ?? "";
const CURSOR_API_KEY = process.env.CURSOR_API_KEY ?? "";
const CURSOR_MODEL = process.env.CURSOR_MODEL ?? "composer-2.5";
// Server-side OpenAI key used ONLY to mint short-lived Realtime client secrets
// for the app (POST /realtime/token). It never leaves this machine.
const OPENAI_API_KEY = process.env.OPENAI_API_KEY ?? "";
const OPENAI_REALTIME_MODEL = process.env.OPENAI_REALTIME_MODEL ?? "gpt-realtime";
const DEFAULT_CWD = process.env.NOVA_BRIDGE_WORKDIR || process.cwd();
const CLAUDE_BIN = process.env.CLAUDE_BIN || "claude";
const CLAUDE_ARGS = (process.env.CLAUDE_ARGS ?? "").trim();
const CLAUDE_TIMEOUT_MS = Number(process.env.CLAUDE_TIMEOUT_MS ?? 600_000);
const repos = new RepoService({ defaultWorkdir: DEFAULT_CWD });
const previews = new PreviewService();

const app = express();
// Coding prompts can include up to four compressed screenshots. Keep the
// ceiling explicit so arbitrary large uploads cannot exhaust the bridge.
app.use(express.json({ limit: "16mb" }));

// --- Auth -------------------------------------------------------------------
function requireAuth(req: Request, res: Response, next: NextFunction): void {
  if (!TOKEN) {
    res.status(500).json({ ok: false, error: "server_missing_token" });
    return;
  }
  const header = req.get("authorization") ?? "";
  const provided = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!provided || !timingSafeTokenEqual(provided, TOKEN)) {
    res.status(401).json({ ok: false, error: "unauthorized" });
    return;
  }
  next();
}

function sendRepoError(res: Response, err: unknown): void {
  if (err instanceof RepoError) {
    res.status(err.status).json({ ok: false, error: err.code, detail: err.message });
    return;
  }
  res.status(500).json({ ok: false, error: describe(err) });
}

function resolveRequestCwd(body: { repoId?: unknown; cwd?: unknown }): string {
  const repoId = typeof body.repoId === "string" ? body.repoId.trim() : "";
  const legacyCwd = typeof body.cwd === "string" ? body.cwd.trim() : "";
  return repos.resolveCwd(repoId || null, legacyCwd || null);
}

// --- Health (no auth) -------------------------------------------------------
app.get("/health", (_req, res) => {
  const ready = repos.readiness();
  res.json({
    ok: true,
    service: "nova-bridge",
    cursorConfigured: CURSOR_API_KEY.length > 0,
    openaiConfigured: OPENAI_API_KEY.length > 0,
    gitReady: ready.gitReady,
    ghReady: ready.ghReady,
    repoRootCount: ready.rootCount,
    selectedRepoId: repos.listRepos().selectedRepoId,
  });
});

// --- Repositories -----------------------------------------------------------
app.get("/repos", requireAuth, (_req, res) => {
  try {
    const { repos: list, selectedRepoId } = repos.listRepos();
    res.json({ ok: true, selectedRepoId, repos: list, ...repos.readiness() });
  } catch (err) {
    sendRepoError(res, err);
  }
});

app.post("/repos/clone", requireAuth, async (req, res) => {
  try {
    const url = String(req.body?.url ?? "").trim();
    const rootLabel = String(req.body?.rootLabel ?? "").trim() || undefined;
    const summary = await repos.clone(url, rootLabel);
    res.json({ ok: true, repo: summary, selectedRepoId: summary.id });
  } catch (err) {
    sendRepoError(res, err);
  }
});

app.post("/repos/create", requireAuth, async (req, res) => {
  try {
    const result = await repos.createPublicWebProject({
      name: String(req.body?.name ?? ""),
      description:
        typeof req.body?.description === "string"
          ? req.body.description
          : undefined,
      template: String(req.body?.template ?? "react-vite") as
        | "static"
        | "vite"
        | "react-vite"
        | "nextjs",
      rootLabel:
        typeof req.body?.rootLabel === "string"
          ? req.body.rootLabel
          : undefined,
    });
    res.status(201).json({ ok: true, ...result });
  } catch (err) {
    sendRepoError(res, err);
  }
});

app.post("/repos/select", requireAuth, (req, res) => {
  try {
    const repoId = String(req.body?.repoId ?? "").trim();
    if (!repoId) {
      res.status(400).json({ ok: false, error: "missing_repo_id" });
      return;
    }
    const summary = repos.selectRepo(repoId);
    res.json({ ok: true, repo: summary, selectedRepoId: summary.id });
  } catch (err) {
    sendRepoError(res, err);
  }
});

app.get("/repos/:repoId/status", requireAuth, async (req, res) => {
  try {
    const status = await repos.status(String(req.params.repoId ?? ""));
    res.json({ ok: true, status });
  } catch (err) {
    sendRepoError(res, err);
  }
});

app.get("/repos/:repoId/diff", requireAuth, async (req, res) => {
  try {
    const diff = await repos.diff(String(req.params.repoId ?? ""));
    res.json({ ok: true, ...diff });
  } catch (err) {
    sendRepoError(res, err);
  }
});

app.get("/repos/:repoId/files", requireAuth, (req, res) => {
  try {
    const requestedPath =
      typeof req.query.path === "string" ? req.query.path.trim() : "";
    const listing = repos.listFiles(String(req.params.repoId ?? ""), requestedPath);
    res.json({ ok: true, ...listing });
  } catch (err) {
    sendRepoError(res, err);
  }
});

app.post("/repos/:repoId/publish", requireAuth, async (req, res) => {
  try {
    const result = await repos.publish(String(req.params.repoId ?? ""), {
      statusToken: String(req.body?.statusToken ?? ""),
      branchName: typeof req.body?.branchName === "string" ? req.body.branchName : undefined,
      commitMessage: String(req.body?.commitMessage ?? ""),
      prTitle: String(req.body?.prTitle ?? ""),
      prBody: typeof req.body?.prBody === "string" ? req.body.prBody : undefined,
      paths: Array.isArray(req.body?.paths)
        ? req.body.paths.filter((p: unknown): p is string => typeof p === "string")
        : undefined,
    });
    res.json({ ok: true, ...result });
  } catch (err) {
    sendRepoError(res, err);
  }
});

// --- Live preview -----------------------------------------------------------
// Serves generated projects on LAN ports the phone's browser can open. Dev
// servers (vite/next) start asynchronously; the app polls until state=ready.
app.get("/preview", requireAuth, (req, res) => {
  const host = req.get("host");
  const list = previews.list().map((p) => ({
    ...p,
    url: previewTargetUrl(host, p.port, p.urlPath),
  }));
  res.json({ ok: true, previews: list });
});

app.post("/preview/start", requireAuth, async (req, res) => {
  const repoId = String(req.body?.repoId ?? "").trim();
  if (!repoId) {
    res.status(400).json({ ok: false, error: "missing_repo_id" });
    return;
  }
  try {
    const requestedPath =
      typeof req.body?.path === "string" ? req.body.path.trim() : "";
    const target = repos.resolveRepoPath(repoId, requestedPath);
    // A folder is its own preview root (and may contain its own Vite/Next app).
    // A file is served from the repository root so relative assets still work;
    // Safari opens its encoded repository-relative URL directly.
    const serveDir =
      target.kind === "directory" ? target.absolutePath : target.repoPath;
    const urlPath =
      target.kind === "file" ? target.relativePath : "";
    const info = await previews.start(
      target.repoId,
      serveDir,
      target.name,
      target.relativePath,
      urlPath,
    );
    res.json({
      ok: true,
      preview: {
        ...info,
        url: previewTargetUrl(req.get("host"), info.port, info.urlPath),
      },
    });
  } catch (err) {
    sendRepoError(res, err);
  }
});

function previewTargetUrl(
  host: string | undefined,
  port: number,
  relativePath?: string,
): string {
  const base = previewUrl(host, port);
  if (!relativePath) return base;
  return (
    base +
    relativePath
      .split("/")
      .filter(Boolean)
      .map((part) => encodeURIComponent(part))
      .join("/")
  );
}

app.post("/preview/stop", requireAuth, async (req, res) => {
  const repoId = String(req.body?.repoId ?? "").trim();
  if (!repoId) {
    res.status(400).json({ ok: false, error: "missing_repo_id" });
    return;
  }
  try {
    const stopped = await previews.stop(repoId);
    res.json({ ok: true, stopped });
  } catch (err) {
    res.status(500).json({ ok: false, error: describe(err) });
  }
});

// --- OpenAI Realtime ephemeral token ---------------------------------------
// Mints a short-lived GA Realtime client secret (`ek_...`) so the iOS app never
// has to ship the standard OpenAI key. The app authenticates with its bridge
// bearer token, then uses the returned `value` directly for the Realtime socket.
app.post("/realtime/token", requireAuth, async (req, res) => {
  if (!OPENAI_API_KEY) {
    res.status(500).json({ ok: false, error: "openai_api_key_missing" });
    return;
  }
  const model = String(req.body?.model ?? "").trim() || OPENAI_REALTIME_MODEL;
  try {
    const upstream = await fetch(
      "https://api.openai.com/v1/realtime/client_secrets",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${OPENAI_API_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ session: { type: "realtime", model } }),
      },
    );
    const text = await upstream.text();
    if (!upstream.ok) {
      res.status(502).json({
        ok: false,
        error: "openai_client_secrets_failed",
        status: upstream.status,
        detail: text.slice(0, 500),
      });
      return;
    }
    const data = JSON.parse(text) as { value?: string; expires_at?: number };
    if (!data.value) {
      res.status(502).json({ ok: false, error: "openai_no_secret" });
      return;
    }
    res.json({
      ok: true,
      value: data.value,
      expires_at: data.expires_at,
      model,
    });
  } catch (err) {
    res.status(500).json({ ok: false, error: describe(err) });
  }
});

// --- Claude Code ------------------------------------------------------------
app.post("/claude-code", requireAuth, async (req, res) => {
  const prompt = String(req.body?.prompt ?? "").trim();
  if (!prompt) {
    res.status(400).json({ ok: false, error: "missing_prompt" });
    return;
  }
  let cwd: string;
  try {
    cwd = resolveRequestCwd(req.body ?? {});
  } catch (err) {
    sendRepoError(res, err);
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

type PromptImage = {
  data: string;
  mimeType: "image/jpeg" | "image/png" | "image/webp";
  dimension?: { width: number; height: number };
};

function parsePromptImages(raw: unknown): PromptImage[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) {
    throw new RepoError("invalid_images", "images_must_be_an_array", 400);
  }
  if (raw.length > 4) {
    throw new RepoError("too_many_images", "maximum_4_images", 413);
  }
  let totalBytes = 0;
  return raw.map((value, index) => {
    if (!value || typeof value !== "object") {
      throw new RepoError("invalid_image", `image_${index}_must_be_an_object`, 400);
    }
    const image = value as Record<string, unknown>;
    const mimeType = String(image.mimeType ?? "").toLowerCase();
    if (!["image/jpeg", "image/png", "image/webp"].includes(mimeType)) {
      throw new RepoError("unsupported_image_type", `image_${index}:${mimeType}`, 415);
    }
    const data = typeof image.data === "string" ? image.data : "";
    if (!data || data.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(data)) {
      throw new RepoError("invalid_image_data", `image_${index}_invalid_base64`, 400);
    }
    const bytes = Buffer.from(data, "base64").byteLength;
    if (bytes === 0 || bytes > 3_000_000) {
      throw new RepoError("image_too_large", `image_${index}_maximum_3mb`, 413);
    }
    totalBytes += bytes;
    if (totalBytes > 8_000_000) {
      throw new RepoError("images_too_large", "maximum_8mb_total", 413);
    }
    const width = Number(image.width);
    const height = Number(image.height);
    const dimension =
      Number.isInteger(width) && width > 0 && Number.isInteger(height) && height > 0
        ? { width, height }
        : undefined;
    return {
      data,
      mimeType: mimeType as PromptImage["mimeType"],
      ...(dimension ? { dimension } : {}),
    };
  });
}

app.post("/cursor/command", requireAuth, async (req, res) => {
  const command = String(req.body?.command ?? "").trim();
  const sessionId = String(req.body?.sessionId ?? "").trim();
  if (!command) {
    res.status(400).json({ ok: false, error: "missing_command" });
    return;
  }
  if (!CURSOR_API_KEY) {
    res.status(500).json({ ok: false, error: "cursor_api_key_missing" });
    return;
  }
  let cwd: string;
  try {
    cwd = resolveRequestCwd(req.body ?? {});
  } catch (err) {
    sendRepoError(res, err);
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
  const requestedCommand = String(req.body?.command ?? "").trim();
  const sessionId = String(req.body?.sessionId ?? "").trim();
  let images: PromptImage[];
  try {
    images = parsePromptImages(req.body?.images);
  } catch (err) {
    sendRepoError(res, err);
    return;
  }
  if (!requestedCommand && images.length === 0) {
    res.status(400).json({ ok: false, error: "missing_command" });
    return;
  }
  const command =
    requestedCommand ||
    "Analyze the attached image. Identify any visible error and recommend the next debugging steps.";
  if (!CURSOR_API_KEY) {
    res.status(500).json({ ok: false, error: "cursor_api_key_missing" });
    return;
  }

  let cwd: string;
  try {
    cwd = resolveRequestCwd(req.body ?? {});
  } catch (err) {
    sendRepoError(res, err);
    return;
  }

  res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
  res.setHeader("Cache-Control", "no-cache, no-transform");
  res.setHeader("Connection", "keep-alive");
  res.setHeader("X-Accel-Buffering", "no");
  if (typeof res.flushHeaders === "function") res.flushHeaders();
  // Small SSE frames otherwise sit in Nagle/TCP buffers on Windows — the phone
  // stays on "Connecting to bridge…" even though the agent is already running.
  try {
    res.socket?.setNoDelay(true);
  } catch {
    /* ignore */
  }

  const flush = (): void => {
    const flushable = res as Response & { flush?: () => void };
    if (typeof flushable.flush === "function") {
      try {
        flushable.flush();
      } catch {
        /* ignore */
      }
    }
  };
  const write = (event: CodingEvent): void => {
    if (res.writableEnded) return;
    try {
      res.write(formatSse(event));
      flush();
    } catch {
      /* connection already gone */
    }
  };
  const writeComment = (text: string): void => {
    if (res.writableEnded) return;
    try {
      res.write(`: ${text}\n\n`);
      flush();
    } catch {
      /* connection already gone */
    }
  };

  // Emit body bytes immediately. iOS drops SSE if Agent.create/resume blocks
  // for a long time with only headers and no payload.
  write({ type: "status", status: "CONNECTING" });
  write({
    type: "activity",
    phase: "status",
    text: sessionId ? "Resuming Cursor session…" : "Creating Cursor agent…",
    detail: cwd,
    done: false,
  });
  writeComment(`setup ${Date.now()}`);

  // Aggressive keepalives during Agent.create/resume; relax once RUNNING.
  let keepaliveMs = 4_000;
  let keepalive = setInterval(() => writeComment(`keepalive ${Date.now()}`), keepaliveMs);
  const setKeepaliveMs = (ms: number): void => {
    if (ms === keepaliveMs) return;
    keepaliveMs = ms;
    clearInterval(keepalive);
    keepalive = setInterval(() => writeComment(`keepalive ${Date.now()}`), keepaliveMs);
  };
  req.on("close", () => clearInterval(keepalive));

  let agent: Awaited<ReturnType<typeof import("@cursor/sdk").Agent.create>> | null =
    null;
  let runId = "";
  let resolvedSessionId = sessionId;

  const withTimeout = async <T>(
    label: string,
    promise: Promise<T>,
    ms: number,
  ): Promise<T> => {
    let timer: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([
        promise,
        new Promise<T>((_, reject) => {
          timer = setTimeout(
            () => reject(new Error(`${label}_timeout_after_${ms}ms`)),
            ms,
          );
        }),
      ]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  };

  try {
    const setupStarted = Date.now();
    const { Agent, configureCursorSdk } = await import("@cursor/sdk");
    // NordVPN / some Windows stacks break HTTP/2 agent streams → empty UI.
    try {
      configureCursorSdk({ local: { useHttp1ForAgent: true } });
    } catch {
      /* older SDKs may not accept this */
    }

    try {
      agent = sessionId
        ? await withTimeout(
            "agent_resume",
            Agent.resume(sessionId, { apiKey: CURSOR_API_KEY }),
            90_000,
          )
        : await withTimeout(
            "agent_create",
            Agent.create({
              apiKey: CURSOR_API_KEY,
              model: { id: CURSOR_MODEL },
              local: { cwd },
            }),
            90_000,
          );
    } catch (err) {
      // Stale/corrupt session pins often hang or fail resume. Fall back once.
      if (sessionId) {
        console.log(
          `[cursor/runs] resume failed (${describe(err)}); creating fresh agent`,
        );
        write({
          type: "activity",
          phase: "status",
          text: "Resume failed — starting a new session…",
          detail: describe(err),
          done: false,
        });
        agent = await withTimeout(
          "agent_create_fallback",
          Agent.create({
            apiKey: CURSOR_API_KEY,
            model: { id: CURSOR_MODEL },
            local: { cwd },
          }),
          90_000,
        );
      } else {
        throw err;
      }
    }

    resolvedSessionId = agent.agentId;
    console.log(
      `[cursor/runs] agent ready in ${Date.now() - setupStarted}ms id=${resolvedSessionId}`,
    );
    write({ type: "status", status: "CREATING", sessionId: resolvedSessionId });
    write({
      type: "activity",
      phase: "status",
      text: "Agent ready — sending prompt…",
      detail: resolvedSessionId,
      done: false,
    });

    let sawAssistant = false;
    // Live Agents-window style updates come from onDelta/onStep. Coarse
    // run.stream() messages often include empty thinking placeholders and are
    // easy to miss — keep them as a secondary feed only.
    const emit = (events: CodingEvent[]): void => {
      for (const event of events) {
        if (event.type === "assistant_delta") sawAssistant = true;
        write(event);
      }
    };

    const message =
      images.length > 0 ? { text: command, images } : command;
    console.log(`[cursor/runs] sending prompt (${command.length} chars, ${images.length} images)`);
    const run = await withTimeout(
      "agent_send",
      agent.send(message, {
        onDelta: ({ update }) => {
          emit(normalizeInteractionUpdate(update));
        },
        onStep: ({ step }) => {
          emit(normalizeConversationStep(step));
        },
      }),
      60_000,
    );
    runId = run.id;
    activeRuns.set(runId, {
      agentId: resolvedSessionId,
      cancel: () => run.cancel(),
    });
    setKeepaliveMs(12_000);
    console.log(`[cursor/runs] run started id=${runId}`);
    write({
      type: "status",
      status: "RUNNING",
      runId,
      sessionId: resolvedSessionId,
    });
    write({
      type: "activity",
      phase: "status",
      text: "Running",
      detail: runId,
      done: false,
    });
    if (images.length > 0) {
      write({
        type: "activity",
        phase: "attachment",
        text: `${images.length} image${images.length === 1 ? "" : "s"} attached`,
        done: true,
      });
    }

    // Drain the SDK message stream in parallel with wait() for envelopes that
    // onDelta does not cover (status/usage/system/task). Skip assistant /
    // thinking / tool_call — those already stream via onDelta.
    const streamDrain = (async () => {
      try {
        for await (const msg of run.stream()) {
          const type = (msg as { type?: string } | null)?.type;
          if (
            type === "assistant" ||
            type === "thinking" ||
            type === "tool_call" ||
            type === "user" ||
            type === "text-delta" ||
            type === "thinking-delta"
          ) {
            continue;
          }
          const events = normalizeSdkMessage(msg);
          if (events.length === 0) {
            console.log(
              `[cursor/runs] unmapped stream message ${describeUnknownMessage(msg)}`,
            );
          }
          emit(events);
        }
      } catch (err) {
        console.log(`[cursor/runs] stream drain error: ${describe(err)}`);
      }
    })();

    console.log(`[cursor/runs] waiting for run ${runId}`);
    // Heartbeat while wait() can sit silent for a long time (tools / thinking).
    const waitHeartbeat = setInterval(() => {
      write({
        type: "activity",
        phase: "status",
        text: "Still working…",
        detail: runId,
        done: false,
      });
    }, 15_000);
    let result: Awaited<ReturnType<typeof run.wait>>;
    try {
      result = await withTimeout("run_wait", run.wait(), 10 * 60_000);
    } finally {
      clearInterval(waitHeartbeat);
    }
    await streamDrain.catch(() => undefined);
    console.log(`[cursor/runs] run ${runId} finished status=${result.status}`);

    // If neither deltas nor stream produced assistant text, fall back to wait().
    if (!sawAssistant && result.result?.trim()) {
      write({ type: "assistant_delta", text: result.result.trim() });
    }
    write({
      type: "activity",
      phase: "status",
      text: result.status === "finished" ? "Finished" : result.status,
      done: true,
    });
    write({
      type: "done",
      sessionId: resolvedSessionId,
      runId,
      status: result.status,
      result: result.result ?? "",
    });
  } catch (err) {
    const message = describe(err);
    console.log(`[cursor/runs] error: ${message}`);
    const friendly =
      message.includes("timeout_after_")
        ? `Cursor agent timed out (${message}). Tap New session and try again.`
        : message;
    write({ type: "error", error: friendly });
    write({
      type: "activity",
      phase: "status",
      text: "Failed to start",
      detail: friendly,
      done: true,
    });
    write({
      type: "done",
      sessionId: resolvedSessionId || sessionId || "unknown",
      runId: runId || "unknown",
      status: "error",
      result: "",
    });
  } finally {
    clearInterval(keepalive);
    if (runId) activeRuns.delete(runId);
    if (agent) {
      try {
        await withTimeout("agent_dispose", disposeAgent(agent), 10_000);
      } catch (err) {
        console.log(`[cursor/runs] dispose timed out/failed: ${describe(err)}`);
      }
    }
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
  const ready = repos.readiness();
  console.log(`Nova Bridge listening on http://0.0.0.0:${PORT}`);
  console.log(`  token set:       ${TOKEN ? "yes" : "NO (set NOVA_BRIDGE_TOKEN)"}`);
  console.log(`  cursor api key:  ${CURSOR_API_KEY ? "yes" : "no"}`);
  console.log(`  openai api key:  ${OPENAI_API_KEY ? "yes" : "no (realtime token endpoint disabled)"}`);
  console.log(`  ripgrep:         ${RIPGREP_PATH ?? "MISSING — Coding agents may hang with empty output"}`);
  console.log(`  git:             ${ready.gitBin ?? "MISSING"}`);
  console.log(`  gh:              ${ready.ghBin ?? "MISSING"}`);
  console.log(`  repo roots:      ${ready.rootCount}`);
  console.log(`  default cwd:     ${DEFAULT_CWD}`);
});
