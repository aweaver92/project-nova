import express, { type Request, type Response, type NextFunction } from "express";
import { spawn } from "node:child_process";
import { readFileSync, existsSync, realpathSync, promises as fs } from "node:fs";
import { request as httpRequest } from "node:http";
import path, { resolve } from "node:path";
import { fileURLToPath } from "node:url";
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
import { advertiseBridge, type BridgeAdvertisement } from "./bonjour-discovery.js";
import {
  buildPreviewUrls,
  PreviewService,
  tailscaleIPv4,
} from "./preview-service.js";
import { RepoError, RepoService, timingSafeTokenEqual } from "./repo-service.js";

/**
 * Nova Bridge — implements the wire contract the Nova iOS app's `NovaBridgeClient`
 * expects (all JSON, bearer-authenticated):
 *   POST /realtime/token           { model? }               → { value, expires_at }
 *   POST /claude-code              { prompt, repoId?, cwd?, actionId?, detach? }
 *   GET  /claude-code/:actionId    → { status: running|done, ... }
 *   POST /cursor/command           { command, sessionId?, repoId? }
 *   POST /cursor/runs              { command, sessionId?, repoId? }  → SSE stream
 *   POST /cursor/runs/:runId/cancel
 *   GET  /cursor/sessions
 *   GET  /cursor/sessions/:id/messages
 *   GET  /repos
 *   POST /repos/clone | /repos/create | /repos/select
 *   GET  /repos/:repoId/status | /diff | /files?path=
 *   POST /self-code/search | /self-code/read       → read-only Nova grounding
 *   POST /repos/:repoId/publish
 *   POST /nova/commit-and-build        → commit+push Nova checkout, build IPA
 *   POST /repos/:repoId/baselines                 → create pre-run snapshot
 *   GET  /repos/:repoId/baselines/:id/review      → agent-only file diffs
 *   POST /repos/:repoId/baselines/:id/keep        { paths }
 *   POST /repos/:repoId/baselines/:id/restore     { paths, contentTokens? }
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
const HOST = process.env.HOST?.trim() || "0.0.0.0";
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

// The bridge runs from the same monorepo the coding agent edits, so a stray
// `cd nova-bridge` + restart could kill the service mid-task. Compute our own
// package dir once (parent of this src/ file) and refuse to run coding commands
// that resolve into it.
const BRIDGE_SELF_DIR = (() => {
  try {
    return realpathSync(path.dirname(path.dirname(fileURLToPath(import.meta.url))));
  } catch {
    return path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  }
})();

function assertNotBridgeSelf(cwd: string): void {
  let resolved: string;
  try {
    resolved = realpathSync(resolve(cwd));
  } catch {
    resolved = resolve(cwd);
  }
  if (resolved === BRIDGE_SELF_DIR || resolved.startsWith(BRIDGE_SELF_DIR + path.sep)) {
    throw new RepoError(
      "bridge_protected",
      "coding_in_nova_bridge_dir_blocked",
      403,
    );
  }
}

function resolveRequestCwd(body: { repoId?: unknown; cwd?: unknown }): string {
  const repoId = typeof body.repoId === "string" ? body.repoId.trim() : "";
  const legacyCwd = typeof body.cwd === "string" ? body.cwd.trim() : "";
  const cwd = repos.resolveCwd(repoId || null, legacyCwd || null);
  assertNotBridgeSelf(cwd);
  return cwd;
}

function resolveQueryCwd(req: Request): string {
  return resolveRequestCwd({
    repoId: typeof req.query.repoId === "string" ? req.query.repoId : undefined,
    cwd: typeof req.query.cwd === "string" ? req.query.cwd : undefined,
  });
}

// --- Health (no auth) -------------------------------------------------------
app.get("/health", (_req, res) => {
  const ready = repos.readiness();
  const tsIp = tailscaleIPv4();
  res.json({
    ok: true,
    service: "nova-bridge",
    cursorConfigured: CURSOR_API_KEY.length > 0,
    openaiConfigured: OPENAI_API_KEY.length > 0,
    gitReady: ready.gitReady,
    ghReady: ready.ghReady,
    repoRootCount: ready.rootCount,
    selectedRepoId: repos.listRepos().selectedRepoId,
    defaultCwd: DEFAULT_CWD,
    tokenConfigured: TOKEN.length > 0,
    tailscaleIp: tsIp,
    previewRemoteReady: Boolean(tsIp),
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

// --- Nova self-knowledge (read-only) ---------------------------------------
app.post("/self-code/search", requireAuth, (req, res) => {
  try {
    const query = String(req.body?.query ?? "").trim();
    const result = repos.searchNovaCode(query);
    res.json({
      ok: true,
      ...result,
      guidance:
        "These matches describe the configured source checkout, which may differ from the installed IPA. Use them only as leads; read relevant lines before making a claim.",
    });
  } catch (err) {
    sendRepoError(res, err);
  }
});

app.post("/self-code/read", requireAuth, (req, res) => {
  try {
    const path = String(req.body?.path ?? "").trim();
    const startLine = Number(req.body?.startLine ?? 1);
    const endLine = Number(req.body?.endLine ?? startLine + 119);
    if (!path) {
      res.status(400).json({ ok: false, error: "path_required" });
      return;
    }
    if (
      !Number.isFinite(startLine) ||
      !Number.isFinite(endLine) ||
      !Number.isInteger(startLine) ||
      !Number.isInteger(endLine) ||
      startLine < 1 ||
      endLine < startLine
    ) {
      res.status(400).json({ ok: false, error: "invalid_line_range" });
      return;
    }
    const result = repos.readNovaCode(path, startLine, endLine);
    res.json({
      ok: true,
      ...result,
      citation: `${result.path}:${result.startLine}-${result.endLine}`,
      guidance:
        "Answer from this checkout evidence and cite it. Do not claim installed-build availability unless separately established. If evidence is insufficient, search/read more or say so.",
    });
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

app.post("/nova/commit-and-build", requireAuth, async (req, res) => {
  try {
    const result = await repos.commitAndBuildIpa({
      statusToken:
        typeof req.body?.statusToken === "string" ? req.body.statusToken : undefined,
      commitMessage:
        typeof req.body?.commitMessage === "string" ? req.body.commitMessage : undefined,
    });
    res.json({ ok: true, ...result });
  } catch (err) {
    sendRepoError(res, err);
  }
});

app.post("/repos/:repoId/baselines", requireAuth, async (req, res) => {
  try {
    const created = await repos.createBaseline(String(req.params.repoId ?? ""));
    res.json({ ok: true, ...created });
  } catch (err) {
    sendRepoError(res, err);
  }
});

app.get("/repos/:repoId/baselines/:baselineId/review", requireAuth, async (req, res) => {
  try {
    const review = await repos.agentReview(
      String(req.params.repoId ?? ""),
      String(req.params.baselineId ?? ""),
    );
    res.json({ ok: true, review });
  } catch (err) {
    sendRepoError(res, err);
  }
});

app.post("/repos/:repoId/baselines/:baselineId/keep", requireAuth, async (req, res) => {
  try {
    const paths = Array.isArray(req.body?.paths)
      ? req.body.paths.filter((p: unknown): p is string => typeof p === "string")
      : [];
    if (!paths.length) {
      res.status(400).json({ ok: false, error: "missing_paths" });
      return;
    }
    const review = await repos.keepReviewPaths(
      String(req.params.repoId ?? ""),
      String(req.params.baselineId ?? ""),
      paths,
    );
    res.json({ ok: true, review });
  } catch (err) {
    sendRepoError(res, err);
  }
});

app.post("/repos/:repoId/baselines/:baselineId/restore", requireAuth, async (req, res) => {
  try {
    const paths = Array.isArray(req.body?.paths)
      ? req.body.paths.filter((p: unknown): p is string => typeof p === "string")
      : [];
    if (!paths.length) {
      res.status(400).json({ ok: false, error: "missing_paths" });
      return;
    }
    const contentTokens =
      req.body?.contentTokens && typeof req.body.contentTokens === "object"
        ? (req.body.contentTokens as Record<string, string>)
        : undefined;
    const review = await repos.restoreReviewPaths(
      String(req.params.repoId ?? ""),
      String(req.params.baselineId ?? ""),
      paths,
      contentTokens,
    );
    res.json({ ok: true, review });
  } catch (err) {
    sendRepoError(res, err);
  }
});

// --- Live preview -----------------------------------------------------------
// Serves generated projects on LAN ports the phone's browser can open. Dev
// servers (vite/next) start asynchronously; the app polls until state=ready.
// When the phone reaches the bridge over Tailscale/HTTPS, URLs prefer the
// Tailscale CGNAT IP (peer-to-peer) or fall back to /preview-proxy/:repoId.
app.get("/preview", requireAuth, (req, res) => {
  const list = previews.list().map((p) => attachPreviewUrls(req, p));
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
      preview: attachPreviewUrls(req, info),
    });
  } catch (err) {
    sendRepoError(res, err);
  }
});

function bridgeOriginFromRequest(req: Request): string {
  const host = req.get("host") ?? "127.0.0.1";
  const xf = (req.get("x-forwarded-proto") ?? "").split(",")[0]?.trim();
  const proto =
    xf ||
    (host.toLowerCase().includes(".ts.net") || req.secure ? "https" : req.protocol) ||
    "http";
  return `${proto}://${host}`;
}

function attachPreviewUrls(
  req: Request,
  preview: { repoId: string; port: number; urlPath?: string },
): Record<string, unknown> {
  const urls = buildPreviewUrls({
    requestHostHeader: req.get("host"),
    bridgeOrigin: bridgeOriginFromRequest(req),
    port: preview.port,
    repoId: preview.repoId,
    relativePath: preview.urlPath,
  });
  return { ...preview, ...urls };
}

/**
 * Unauthenticated reverse proxy for remote Safari previews (same trust model as
 * LAN preview ports: project content only, never bridge APIs).
 */
app.use("/preview-proxy/:repoId", (req, res) => {
  const repoId = String(req.params.repoId ?? "").trim();
  const preview = previews.get(repoId);
  if (!preview || preview.state !== "ready") {
    res.status(404).json({ ok: false, error: "preview_not_ready" });
    return;
  }
  // Express strips the mount path; keep a leading slash for the upstream.
  const upstreamPath = req.url && req.url !== "/" ? req.url : "/";
  const proxyReq = httpRequest(
    {
      hostname: "127.0.0.1",
      port: preview.port,
      path: upstreamPath,
      method: req.method,
      headers: {
        ...req.headers,
        host: `127.0.0.1:${preview.port}`,
      },
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode ?? 502, proxyRes.headers);
      proxyRes.pipe(res);
    },
  );
  proxyReq.on("error", (err) => {
    if (!res.headersSent) {
      res.status(502).json({ ok: false, error: "preview_proxy_failed", detail: err.message });
    } else {
      res.end();
    }
  });
  req.pipe(proxyReq);
});

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

// --- Realtime mic diagnose (phone → bridge dump) ----------------------------
// The iOS app uploads a recent outbound PCM clip when client VAD commits (or
// cloud-quiet fires). We save a WAV and run peak/zcr stats so we can iterate on
// the mic path WITHOUT another IPA sideload. Optional live Realtime probe.
app.post("/realtime/diagnose", requireAuth, async (req, res) => {
  try {
    const sampleRate = Number(req.body?.sample_rate ?? 24000) || 24000;
    const meta = (req.body?.meta && typeof req.body.meta === "object")
      ? req.body.meta
      : {};
    const b64 = String(req.body?.pcm_b64 ?? "");
    if (!b64) {
      res.status(400).json({ ok: false, error: "missing_pcm_b64" });
      return;
    }
    const pcm = Buffer.from(b64, "base64");
    if (pcm.length < 100) {
      res.status(400).json({ ok: false, error: "pcm_too_short", bytes: pcm.length });
      return;
    }

    const dir = path.join(process.cwd(), "diagnostics");
    await fs.mkdir(dir, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    const build = String(meta.build ?? "unknown").replace(/[^\w.-]+/g, "_");
    const wavPath = path.join(dir, `realtime-${stamp}-${build}.wav`);
    await fs.writeFile(wavPath, pcm16ToWav(pcm, sampleRate));

    const stats = pcmStats(pcm);
    const payload = {
      ok: true,
      path: wavPath,
      bytes: pcm.length,
      seconds: pcm.length / 2 / sampleRate,
      sample_rate: sampleRate,
      meta,
      stats,
      hint:
        stats.zcr < 0.01
          ? "zcr≈0 with high peak → likely DC/stuck converter, not speech"
          : "speech-like zcr; replay with: npm run test:realtime:dump -- \"" + wavPath + "\"",
    };
    console.log("[realtime/diagnose]", JSON.stringify({
      path: wavPath,
      seconds: payload.seconds,
      stats,
      build: meta.build,
    }));
    res.json(payload);
  } catch (err) {
    res.status(500).json({ ok: false, error: describe(err) });
  }
});

function pcmStats(pcm: Buffer) {
  const samples = pcm.length / 2;
  if (samples < 2) return { peak: 0, rms: 0, zcr: 0 };
  let peak = 0;
  let sumSq = 0;
  let crossings = 0;
  let prev = 0;
  for (let i = 0; i < samples; i++) {
    const s = pcm.readInt16LE(i * 2);
    const a = Math.abs(s);
    if (a > peak) peak = a;
    sumSq += s * s;
    if (i > 0 && ((prev >= 0 && s < 0) || (prev < 0 && s >= 0))) crossings++;
    prev = s;
  }
  return {
    peak: peak / 32767,
    rms: Math.sqrt(sumSq / samples) / 32767,
    zcr: crossings / (samples - 1),
  };
}

function pcm16ToWav(pcm: Buffer, sampleRate: number) {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20); // PCM
  header.writeUInt16LE(1, 22); // mono
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

// --- Claude Code ------------------------------------------------------------
type ClaudeJobResult = {
  ok: boolean;
  exitCode?: number;
  result?: string;
  stderr?: string;
  error?: string;
};
type ClaudeJobEntry = {
  startedAt: number;
  promise: Promise<ClaudeJobResult>;
  result?: ClaudeJobResult;
};
const claudeJobs = new Map<string, ClaudeJobEntry>();
const CLAUDE_JOB_TTL_MS = 30 * 60_000;

app.post("/claude-code", requireAuth, async (req, res) => {
  const prompt = String(req.body?.prompt ?? "").trim();
  const suppliedActionId = String(req.body?.actionId ?? "").trim();
  const actionId =
    suppliedActionId || `legacy-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const detach = req.body?.detach === true || req.query?.detach === "1";
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
  let entry = claudeJobs.get(actionId);
  if (!entry) {
    const promise = runClaude(prompt, cwd)
      .then((result): ClaudeJobResult => ({
        ok: result.code === 0,
        exitCode: result.code,
        result: result.stdout.trim(),
        ...(result.stderr.trim() ? { stderr: result.stderr.trim() } : {}),
      }))
      .catch((err): ClaudeJobResult => ({ ok: false, error: describe(err) }));
    entry = { startedAt: Date.now(), promise };
    claudeJobs.set(actionId, entry);
    promise.then((result) => {
      const current = claudeJobs.get(actionId);
      if (current) current.result = result;
    });
    const timer = setTimeout(() => claudeJobs.delete(actionId), CLAUDE_JOB_TTL_MS);
    timer.unref?.();
  }

  // Detached mode: return immediately so the phone can lock; poll GET for status.
  // The Claude process keeps running on the bridge either way.
  if (detach && !entry.result) {
    res.status(202).json({
      ok: true,
      status: "running",
      actionId,
      startedAt: entry.startedAt,
    });
    return;
  }

  // Repeated requests with the same actionId await the original process. This
  // makes phone-side reconnect retries idempotent instead of spawning duplicate
  // Claude Code edits after an HTTP connection loss.
  const result = await entry.promise;
  res.json({ ...result, actionId, status: "done" });
});

app.get("/claude-code/:actionId", requireAuth, (req, res) => {
  const actionId = String(req.params.actionId ?? "").trim();
  if (!actionId) {
    res.status(400).json({ ok: false, error: "missing_action_id" });
    return;
  }
  const entry = claudeJobs.get(actionId);
  if (!entry) {
    res.status(404).json({
      ok: false,
      status: "unknown",
      actionId,
      error: "action_not_found",
      hint: "Job expired, bridge restarted, or actionId never started.",
    });
    return;
  }
  if (!entry.result) {
    res.json({
      ok: true,
      status: "running",
      actionId,
      startedAt: entry.startedAt,
    });
    return;
  }
  res.json({ ...entry.result, actionId, status: "done", startedAt: entry.startedAt });
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

type CursorRunSnapshot = {
  runId: string;
  agentId: string;
  cwd: string;
  status: "running" | "finished" | "error" | "cancelled";
  result: string;
  updatedAt: number;
};

/** In-flight runs keyed by runId for best-effort cancel. */
const activeRuns = new Map<
  string,
  { cancel: () => Promise<void>; agentId: string; cwd: string }
>();
/** Recent status survives an SSE client disconnect so the phone can reattach. */
const runSnapshots = new Map<string, CursorRunSnapshot>();
const RUN_SNAPSHOT_TTL_MS = 30 * 60_000;

function saveRunSnapshot(snapshot: CursorRunSnapshot): void {
  runSnapshots.set(snapshot.runId, snapshot);
  const timer = setTimeout(() => {
    const current = runSnapshots.get(snapshot.runId);
    if (current && Date.now() - current.updatedAt >= RUN_SNAPSHOT_TTL_MS) {
      runSnapshots.delete(snapshot.runId);
    }
  }, RUN_SNAPSHOT_TTL_MS + 1_000);
  timer.unref?.();
}

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
    const modeRaw = String(req.body?.mode ?? "").trim().toLowerCase();
    const cursorMode =
      modeRaw === "plan" || modeRaw === "agent" ? modeRaw : undefined;
    const agent = sessionId
      ? await Agent.resume(sessionId, {
          apiKey: CURSOR_API_KEY,
          model: { id: CURSOR_MODEL },
          local: { cwd },
        })
      : await Agent.create({
          apiKey: CURSOR_API_KEY,
          model: { id: CURSOR_MODEL },
          local: { cwd },
        });
    try {
      const run = await agent.send(command, {
        model: { id: CURSOR_MODEL },
        ...(cursorMode ? { mode: cursorMode } : {}),
      });
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
            Agent.resume(sessionId, {
              apiKey: CURSOR_API_KEY,
              model: { id: CURSOR_MODEL },
              local: { cwd },
            }),
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
      if (sessionId) {
        console.log(
          `[cursor/runs] resume failed (${describe(err)}); preserving session context`,
        );
        write({
          type: "activity",
          phase: "status",
          text: "Resume failed — session context was not discarded",
          detail: describe(err),
          done: true,
        });
      }
      throw err;
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
    const modeRaw = String(req.body?.mode ?? "").trim().toLowerCase();
    const cursorMode =
      modeRaw === "plan" || modeRaw === "agent" ? modeRaw : undefined;
    console.log(`[cursor/runs] sending prompt (${command.length} chars, ${images.length} images${cursorMode ? `, mode=${cursorMode}` : ""})`);
    const run = await withTimeout(
      "agent_send",
      agent.send(message, {
        model: { id: CURSOR_MODEL },
        ...(cursorMode ? { mode: cursorMode } : {}),
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
      cwd,
      cancel: () => run.cancel(),
    });
    saveRunSnapshot({
      runId,
      agentId: resolvedSessionId,
      cwd,
      status: "running",
      result: "",
      updatedAt: Date.now(),
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
    saveRunSnapshot({
      runId,
      agentId: resolvedSessionId,
      cwd,
      status: result.status,
      result: result.result ?? "",
      updatedAt: Date.now(),
    });

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
    if (runId) {
      saveRunSnapshot({
        runId,
        agentId: resolvedSessionId,
        cwd,
        status: "error",
        result: message,
        updatedAt: Date.now(),
      });
    }
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

/** Read-only recovery endpoint: inspect an existing run without sending again. */
app.get("/cursor/runs/:runId", requireAuth, async (req, res) => {
  const runId = String(req.params.runId ?? "").trim();
  if (!runId) {
    res.status(400).json({ ok: false, error: "missing_run_id" });
    return;
  }

  const cached = runSnapshots.get(runId);
  if (cached) {
    res.json({
      ok: true,
      runId: cached.runId,
      sessionId: cached.agentId,
      status: cached.status,
      result: cached.result,
    });
    return;
  }

  // Also recover after a bridge restart when the local Cursor SDK persisted the
  // run. No prompt is sent here: getRun is an idempotent read/reattach operation.
  try {
    const { Agent } = await import("@cursor/sdk");
    const run = await Agent.getRun(runId, { runtime: "local" });
    const snapshot: CursorRunSnapshot = {
      runId,
      agentId: run.agentId,
      cwd: "",
      status: run.status,
      result: run.result ?? "",
      updatedAt: Date.now(),
    };
    saveRunSnapshot(snapshot);
    res.json({
      ok: true,
      runId,
      sessionId: run.agentId,
      status: run.status,
      result: run.result ?? "",
    });
  } catch (err) {
    res.status(404).json({
      ok: false,
      error: "run_not_found",
      detail: describe(err),
      runId,
    });
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
      saveRunSnapshot({
        runId,
        agentId: tracked.agentId,
        cwd: tracked.cwd,
        status: "cancelled",
        result: "",
        updatedAt: Date.now(),
      });
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
    const existing = runSnapshots.get(runId);
    if (existing) {
      saveRunSnapshot({
        ...existing,
        status: "cancelled",
        updatedAt: Date.now(),
      });
    }
    res.json({ ok: true, runId, cancelled: true, source: "sdk" });
  } catch (err) {
    res.status(500).json({ ok: false, error: describe(err) });
  }
});

app.get("/cursor/sessions", requireAuth, async (req, res) => {
  if (!CURSOR_API_KEY) {
    res.status(500).json({ ok: false, error: "cursor_api_key_missing" });
    return;
  }
  let cwd: string;
  try {
    cwd = resolveQueryCwd(req);
  } catch (err) {
    sendRepoError(res, err);
    return;
  }
  try {
    const { Agent } = await import("@cursor/sdk");
    const list = await Agent.list({
      runtime: "local",
      cwd,
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
  let cwd: string;
  try {
    cwd = resolveQueryCwd(req);
  } catch (err) {
    sendRepoError(res, err);
    return;
  }
  try {
    const { Agent } = await import("@cursor/sdk");
    const raw = await Agent.messages.list(id, {
      runtime: "local",
      cwd,
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

let advertisement: BridgeAdvertisement | undefined;
const server = app.listen(PORT, HOST, () => {
  advertisement = advertiseBridge(PORT);
  const ready = repos.readiness();
  console.log(`Nova Bridge listening on http://${HOST}:${PORT}`);
  console.log(`  LAN discovery:   _nova-bridge._tcp (Bonjour/mDNS)`);
  console.log(`  token set:       ${TOKEN ? "yes" : "NO (set NOVA_BRIDGE_TOKEN)"}`);
  console.log(`  cursor api key:  ${CURSOR_API_KEY ? "yes" : "no"}`);
  console.log(`  openai api key:  ${OPENAI_API_KEY ? "yes" : "no (realtime token endpoint disabled)"}`);
  console.log(`  ripgrep:         ${RIPGREP_PATH ?? "MISSING — Coding agents may hang with empty output"}`);
  console.log(`  git:             ${ready.gitBin ?? "MISSING"}`);
  console.log(`  gh:              ${ready.ghBin ?? "MISSING"}`);
  console.log(`  repo roots:      ${ready.rootCount}`);
  console.log(`  default cwd:     ${DEFAULT_CWD}`);
});

// Commit-and-build waits on GitHub Actions IPA CI (often 10–25+ min). Node 18+
// defaults requestTimeout to 5 minutes, which aborts those jobs mid-flight.
server.requestTimeout = 55 * 60_000;
server.headersTimeout = 56 * 60_000;
server.keepAliveTimeout = 120_000;

function shutdown(signal: string): void {
  console.log(`${signal}: stopping Nova Bridge`);
  advertisement?.stop();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5_000).unref();
}

process.once("SIGINT", () => shutdown("SIGINT"));
process.once("SIGTERM", () => shutdown("SIGTERM"));
