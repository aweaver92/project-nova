/**
 * Live preview servers for repos so the phone's browser can open what Claude /
 * Cursor generated. Two modes:
 *
 *  - "static": in-process express static server (plain HTML projects)
 *  - dev server: spawn `npm run dev` bound to 0.0.0.0 (vite / next / generic),
 *    running `npm install` first when node_modules is missing.
 *
 * Preview ports are unauthenticated by design (a browser can't send the bridge
 * bearer token) — they only serve project files / dev servers on your LAN.
 */
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { connect } from "node:net";
import { networkInterfaces } from "node:os";
import { extname, join, normalize, resolve, sep } from "node:path";

export type PreviewKind = "static" | "vite" | "nextjs" | "dev";
export type PreviewState = "installing" | "starting" | "ready" | "error" | "stopped";

export type PreviewInfo = {
  repoId: string;
  name: string;
  /** Repository-relative file/folder selected by the phone (empty = root). */
  path?: string;
  /** URL path to open after the server starts (used for a selected file). */
  urlPath?: string;
  kind: PreviewKind;
  state: PreviewState;
  port: number;
  startedAt: number;
  error?: string;
  /** Last few lines of dev-server output, for diagnostics on the phone. */
  lastOutput?: string;
};

type ActivePreview = PreviewInfo & {
  child?: ChildProcess;
  server?: Server;
  outputRing: string[];
};

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".htm": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".txt": "text/plain; charset=utf-8",
  ".map": "application/json",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".wasm": "application/wasm",
};

/** First non-internal IPv4 (fallback when the request Host header is unusable). */
export function lanIPv4(): string | null {
  for (const addrs of Object.values(networkInterfaces())) {
    for (const addr of addrs ?? []) {
      if (addr.family === "IPv4" && !addr.internal) return addr.address;
    }
  }
  return null;
}

export function detectPreviewKind(dir: string): PreviewKind {
  const pkgPath = join(dir, "package.json");
  if (!existsSync(pkgPath)) return "static";
  try {
    const pkg = JSON.parse(readFileSync(pkgPath, "utf8")) as {
      scripts?: Record<string, string>;
      dependencies?: Record<string, string>;
      devDependencies?: Record<string, string>;
    };
    if (!pkg.scripts?.dev) return "static";
    const deps = { ...pkg.dependencies, ...pkg.devDependencies };
    if (deps.next) return "nextjs";
    if (deps.vite) return "vite";
    return "dev";
  } catch {
    return "static";
  }
}

export function devServerArgs(kind: PreviewKind, port: number): string[] {
  switch (kind) {
    case "nextjs":
      return ["run", "dev", "--", "-H", "0.0.0.0", "-p", String(port)];
    case "vite":
      return ["run", "dev", "--", "--host", "0.0.0.0", "--port", String(port), "--strictPort"];
    default:
      // Generic dev script: many servers honor PORT/HOST env instead.
      return ["run", "dev"];
  }
}

/** Resolve a URL path inside root; null when it escapes or is a dotfile path. */
export function safeStaticPath(root: string, urlPath: string): string | null {
  const decoded = decodeURIComponent(urlPath.split("?")[0] ?? "/");
  const joined = normalize(join(root, decoded));
  const rootNorm = normalize(root + sep);
  if (joined !== normalize(root) && !joined.startsWith(rootNorm)) return null;
  const rel = joined.slice(normalize(root).length);
  for (const part of rel.split(sep)) {
    if (part.startsWith(".")) return null; // .git, .env, dotfiles
  }
  return joined;
}

function probePort(port: number, timeoutMs: number): Promise<boolean> {
  return new Promise((resolvePromise) => {
    const socket = connect({ host: "127.0.0.1", port });
    const finish = (ok: boolean): void => {
      socket.destroy();
      resolvePromise(ok);
    };
    socket.setTimeout(timeoutMs);
    socket.once("connect", () => finish(true));
    socket.once("timeout", () => finish(false));
    socket.once("error", () => finish(false));
  });
}

export class PreviewService {
  private readonly portBase: number;
  private readonly portCount: number;
  private readonly npmBin: string;
  private readonly active = new Map<string, ActivePreview>();

  constructor(opts?: { portBase?: number; portCount?: number; npmBin?: string }) {
    this.portBase = opts?.portBase ?? Number(process.env.NOVA_PREVIEW_PORT_BASE ?? 8790);
    this.portCount = opts?.portCount ?? Number(process.env.NOVA_PREVIEW_PORT_COUNT ?? 10);
    this.npmBin = opts?.npmBin ?? (process.platform === "win32" ? "npm.cmd" : "npm");
    process.once("exit", () => this.stopAllSync());
    process.once("SIGINT", () => {
      this.stopAllSync();
      process.exit(0);
    });
  }

  list(): PreviewInfo[] {
    return [...this.active.values()].map((p) => this.publicInfo(p));
  }

  get(repoId: string): PreviewInfo | null {
    const p = this.active.get(repoId);
    return p ? this.publicInfo(p) : null;
  }

  private publicInfo(p: ActivePreview): PreviewInfo {
    return {
      repoId: p.repoId,
      name: p.name,
      ...(p.path ? { path: p.path } : {}),
      ...(p.urlPath ? { urlPath: p.urlPath } : {}),
      kind: p.kind,
      state: p.state,
      port: p.port,
      startedAt: p.startedAt,
      ...(p.error ? { error: p.error } : {}),
      ...(p.outputRing.length
        ? { lastOutput: p.outputRing.slice(-8).join("\n").slice(-1000) }
        : {}),
    };
  }

  private async allocatePort(): Promise<number> {
    for (let i = 0; i < this.portCount; i++) {
      const port = this.portBase + i;
      const used = [...this.active.values()].some(
        (p) => p.port === port && p.state !== "stopped" && p.state !== "error",
      );
      if (used) continue;
      const busy = await probePort(port, 250);
      if (!busy) return port;
    }
    throw new Error("no_free_preview_port");
  }

  /**
   * Start (or return the existing) preview for a repo. Dev servers become
   * ready asynchronously — poll `get()`/`list()` until state is "ready".
   */
  async start(
    repoId: string,
    dir: string,
    name: string,
    path = "",
    urlPath = "",
  ): Promise<PreviewInfo> {
    const existing = this.active.get(repoId);
    if (
      existing &&
      existing.state !== "error" &&
      existing.state !== "stopped" &&
      (existing.path ?? "") === path &&
      (existing.urlPath ?? "") === urlPath
    ) {
      return this.publicInfo(existing);
    }
    if (existing) await this.stop(repoId);

    const kind = detectPreviewKind(dir);
    const port = await this.allocatePort();
    const preview: ActivePreview = {
      repoId,
      name,
      ...(path ? { path } : {}),
      ...(urlPath ? { urlPath } : {}),
      kind,
      state: "starting",
      port,
      startedAt: Date.now(),
      outputRing: [],
    };
    this.active.set(repoId, preview);

    if (kind === "static") {
      this.startStatic(preview, dir);
    } else {
      // Fire-and-forget: state transitions installing → starting → ready.
      void this.startDev(preview, dir, kind, port);
    }
    return this.publicInfo(preview);
  }

  private startStatic(preview: ActivePreview, dir: string): void {
    const server = createServer((req, res) => {
      const filePath = safeStaticPath(dir, req.url ?? "/");
      if (!filePath) {
        res.writeHead(403).end("Forbidden");
        return;
      }
      const candidates = [filePath];
      if (!extname(filePath)) {
        candidates.push(`${filePath}.html`, join(filePath, "index.html"));
      }
      // SPA-style fallback keeps client-routed pages working.
      candidates.push(join(dir, "index.html"));
      for (const candidate of candidates) {
        try {
          const body = readFileSync(candidate);
          res.writeHead(200, {
            "Content-Type": MIME[extname(candidate).toLowerCase()] ?? "application/octet-stream",
            "Cache-Control": "no-store",
          });
          res.end(body);
          return;
        } catch {
          /* try next candidate */
        }
      }
      res.writeHead(404).end("Not found");
    });
    server.on("error", (err) => {
      preview.state = "error";
      preview.error = err.message;
    });
    server.listen(preview.port, "0.0.0.0", () => {
      preview.state = "ready";
    });
    preview.server = server;
  }

  private appendOutput(preview: ActivePreview, chunk: string): void {
    for (const line of chunk.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      preview.outputRing.push(trimmed);
      if (preview.outputRing.length > 40) preview.outputRing.shift();
    }
  }

  private async startDev(
    preview: ActivePreview,
    dir: string,
    kind: PreviewKind,
    port: number,
  ): Promise<void> {
    try {
      if (!existsSync(join(dir, "node_modules"))) {
        preview.state = "installing";
        const ok = await this.runInstall(preview, dir);
        if (!ok) {
          preview.state = "error";
          preview.error = preview.error ?? "npm_install_failed";
          return;
        }
      }

      preview.state = "starting";
      const child = spawn(this.npmBin, devServerArgs(kind, port), {
        cwd: dir,
        shell: process.platform === "win32",
        env: { ...process.env, PORT: String(port), HOST: "0.0.0.0", BROWSER: "none" },
      });
      preview.child = child;
      child.stdout?.on("data", (d) => this.appendOutput(preview, d.toString()));
      child.stderr?.on("data", (d) => this.appendOutput(preview, d.toString()));
      child.on("error", (err) => {
        preview.state = "error";
        preview.error = err.message;
      });
      child.on("exit", (code) => {
        if (preview.state !== "stopped") {
          preview.state = preview.state === "ready" ? "stopped" : "error";
          if (preview.state === "error") {
            preview.error = preview.error ?? `dev_server_exited_code_${code}`;
          }
        }
      });

      // Wait (in the background) for the port to accept connections. Child
      // event handlers mutate state concurrently, so read via a helper to
      // avoid TS narrowing it to the last local assignment.
      const state = (): PreviewState => preview.state;
      const deadline = Date.now() + 120_000;
      while (Date.now() < deadline) {
        if (state() === "error" || state() === "stopped") return;
        if (await probePort(port, 400)) {
          preview.state = "ready";
          return;
        }
        await new Promise((r) => setTimeout(r, 700));
      }
      if (state() === "starting") {
        preview.state = "error";
        preview.error = "dev_server_not_ready_after_120s";
        this.killChild(preview);
      }
    } catch (err) {
      preview.state = "error";
      preview.error = err instanceof Error ? err.message : String(err);
    }
  }

  private runInstall(preview: ActivePreview, dir: string): Promise<boolean> {
    return new Promise((resolvePromise) => {
      const child = spawn(this.npmBin, ["install", "--no-audit", "--no-fund"], {
        cwd: dir,
        shell: process.platform === "win32",
        env: process.env,
      });
      const timer = setTimeout(() => {
        preview.error = "npm_install_timeout";
        child.kill("SIGKILL");
      }, 300_000);
      child.stdout?.on("data", (d) => this.appendOutput(preview, d.toString()));
      child.stderr?.on("data", (d) => this.appendOutput(preview, d.toString()));
      child.on("error", (err) => {
        clearTimeout(timer);
        preview.error = err.message;
        resolvePromise(false);
      });
      child.on("close", (code) => {
        clearTimeout(timer);
        resolvePromise(code === 0);
      });
    });
  }

  private killChild(preview: ActivePreview): void {
    const child = preview.child;
    if (!child || child.pid === undefined || child.exitCode !== null) return;
    if (process.platform === "win32") {
      // npm spawns a subtree on Windows; kill the whole tree.
      spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { shell: false });
    } else {
      child.kill("SIGTERM");
    }
  }

  async stop(repoId: string): Promise<boolean> {
    const preview = this.active.get(repoId);
    if (!preview) return false;
    preview.state = "stopped";
    this.killChild(preview);
    if (preview.server) {
      await new Promise<void>((r) => preview.server?.close(() => r()));
    }
    this.active.delete(repoId);
    return true;
  }

  private stopAllSync(): void {
    for (const preview of this.active.values()) {
      preview.state = "stopped";
      this.killChild(preview);
      preview.server?.close();
    }
    this.active.clear();
  }
}

/** Preview URL as reachable from the client that made this request. */
export function previewUrl(requestHostHeader: string | undefined, port: number): string {
  const host = (requestHostHeader ?? "").split(":")[0] || lanIPv4() || "127.0.0.1";
  return `http://${host}:${port}/`;
}
