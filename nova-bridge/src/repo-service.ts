import { createHash, timingSafeEqual } from "node:crypto";
import { spawn } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join, resolve as pathResolve, sep } from "node:path";
import { resolveGhBin, resolveGitBin, toolReadiness } from "./tool-paths.js";

/** Names we never descend into while discovering git repos (Dropbox-safe). */
const SKIP_DIR_NAMES = new Set([
  ".git",
  ".cursor",
  ".vs",
  ".venv",
  "node_modules",
  "DerivedData",
  "build",
  "dist",
  "Pods",
  ".dropbox.cache",
]);

const MAX_STDOUT = 512_000;
const MAX_DIFF = 200_000;
const MAX_STATUS_FILES = 200;
const DEFAULT_TIMEOUT_MS = 60_000;
const CLONE_TIMEOUT_MS = 300_000;
const PUBLISH_TIMEOUT_MS = 180_000;

export type RepoSummary = {
  id: string;
  name: string;
  relativePath: string;
  rootLabel: string;
  selected: boolean;
};

export type ChangedFile = {
  path: string;
  status: string;
  staged: boolean;
  unstaged: boolean;
};

export type RepoStatus = {
  repoId: string;
  name: string;
  branch: string;
  upstream: string | null;
  ahead: number;
  behind: number;
  clean: boolean;
  changedFiles: ChangedFile[];
  statusToken: string;
};

export type RepoDiff = {
  repoId: string;
  diff: string;
  truncated: boolean;
  statusToken: string;
};

export type PublishRequest = {
  statusToken: string;
  branchName?: string;
  commitMessage: string;
  prTitle: string;
  prBody?: string;
  paths?: string[];
};

export type PublishResult = {
  repoId: string;
  branch: string;
  commitSha: string;
  prUrl: string;
  prNumber: number | null;
};

export const WEB_PROJECT_TEMPLATES = [
  "static",
  "vite",
  "react-vite",
  "nextjs",
] as const;

export type WebProjectTemplate = (typeof WEB_PROJECT_TEMPLATES)[number];

export type CreateProjectRequest = {
  name: string;
  description?: string;
  template: WebProjectTemplate;
  rootLabel?: string;
};

export type CreateProjectResult = {
  repo: RepoSummary;
  repoUrl: string;
  template: WebProjectTemplate;
  selectedRepoId: string;
};

export class RepoError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(code: string, message: string, status = 400) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

type RootEntry = { label: string; path: string };

type ProcResult = {
  code: number;
  stdout: string;
  stderr: string;
  truncated: boolean;
};

export function defaultRepoRootFromWorkdir(defaultWorkdir: string): string {
  const abs = pathResolve(defaultWorkdir);
  // Prefer the parent of the workdir when it is itself a git repository so
  // sibling clones under the same folder are discoverable.
  try {
    if (existsSync(join(abs, ".git"))) {
      return dirname(abs);
    }
  } catch {
    /* fall through */
  }
  return abs;
}

export function parseRepoRoots(
  envValue: string | undefined,
  defaultWorkdir: string,
): RootEntry[] {
  const raw = (envValue ?? "").trim();
  const paths = raw
    ? raw.split(/[;|]/).map((p) => p.trim()).filter(Boolean)
    : [defaultRepoRootFromWorkdir(defaultWorkdir)];

  const roots: RootEntry[] = [];
  const seen = new Set<string>();
  for (const p of paths) {
    let canonical: string;
    try {
      const abs = pathResolve(p);
      if (!existsSync(abs)) {
        mkdirSync(abs, { recursive: true });
      }
      canonical = realpathSync(abs);
    } catch {
      continue;
    }
    const key = canonical.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    roots.push({ label: basename(canonical) || canonical, path: canonical });
  }
  return roots;
}

export function opaqueRepoId(canonicalPath: string): string {
  return createHash("sha256").update(canonicalPath).digest("hex").slice(0, 16);
}

export function validateProjectName(raw: string): string {
  const name = raw.trim().toLowerCase();
  if (
    !/^[a-z0-9](?:[a-z0-9._-]{0,98}[a-z0-9])?$/.test(name) ||
    name.includes("..") ||
    name.startsWith("-")
  ) {
    throw new RepoError(
      "invalid_project_name",
      "use_1_to_100_lowercase_letters_numbers_dots_hyphens_or_underscores",
    );
  }
  return name;
}

export function validateWebProjectTemplate(raw: string): WebProjectTemplate {
  if ((WEB_PROJECT_TEMPLATES as readonly string[]).includes(raw)) {
    return raw as WebProjectTemplate;
  }
  throw new RepoError(
    "invalid_template",
    `supported_templates:${WEB_PROJECT_TEMPLATES.join(",")}`,
  );
}

export function validateGitHubHttpsUrl(raw: string): {
  owner: string;
  repo: string;
  url: string;
} {
  const trimmed = raw.trim();
  if (!trimmed) throw new RepoError("invalid_url", "missing_url");
  if (/\s/.test(trimmed)) throw new RepoError("invalid_url", "url_contains_whitespace");
  if (trimmed.startsWith("-")) throw new RepoError("invalid_url", "url_looks_like_option");
  if (/^(git@|ssh:|file:|git:)/i.test(trimmed)) {
    throw new RepoError("invalid_url", "only_https_github_urls_allowed");
  }
  if (trimmed.includes("@") && !trimmed.includes("://")) {
    throw new RepoError("invalid_url", "embedded_credentials_rejected");
  }

  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    throw new RepoError("invalid_url", "malformed_url");
  }
  if (url.protocol !== "https:") {
    throw new RepoError("invalid_url", "only_https_allowed");
  }
  if (url.username || url.password) {
    throw new RepoError("invalid_url", "embedded_credentials_rejected");
  }
  if (url.hostname.toLowerCase() !== "github.com") {
    throw new RepoError("invalid_url", "only_github_com_allowed");
  }
  const parts = url.pathname.replace(/\.git$/i, "").split("/").filter(Boolean);
  if (parts.length !== 2) {
    throw new RepoError("invalid_url", "expected_owner_repo_path");
  }
  const [owner, repo] = parts;
  if (!/^[\w.-]+$/.test(owner) || !/^[\w.-]+$/.test(repo)) {
    throw new RepoError("invalid_url", "invalid_owner_or_repo");
  }
  return {
    owner,
    repo,
    url: `https://github.com/${owner}/${repo}.git`,
  };
}

export function sanitizeBranchSlug(input: string): string {
  const trimmed = input.trim().toLowerCase();
  if (!trimmed || trimmed.includes("..") || trimmed.startsWith("/") || trimmed.startsWith("\\")) {
    throw new RepoError("invalid_branch", "invalid_branch_slug");
  }
  if (trimmed === "main" || trimmed === "master" || trimmed === "nova/main" || trimmed === "nova/master") {
    throw new RepoError("invalid_branch", "invalid_branch_slug");
  }
  const slug = trimmed
    .replace(/[^a-z0-9._/-]+/g, "-")
    .replace(/\/+/g, "/")
    .replace(/^-+|-+$/g, "")
    .replace(/^\.+/, "")
    .replace(/^\/+|\/+$/g, "")
    .slice(0, 60);
  if (!slug || slug === "main" || slug === "master" || slug.includes("..") || slug.startsWith("-")) {
    throw new RepoError("invalid_branch", "invalid_branch_slug");
  }
  return slug.startsWith("nova/") ? slug : `nova/${slug}`;
}

export function parsePorcelainStatus(stdout: string): ChangedFile[] {
  const files: ChangedFile[] = [];
  for (const line of stdout.split("\n")) {
    if (line.length < 4) continue;
    const xy = line.slice(0, 2);
    let path = line.slice(3);
    // rename: "R  old -> new"
    if (path.includes(" -> ")) {
      path = path.split(" -> ").pop() ?? path;
    }
    path = path.replace(/^"|"$/g, "");
    if (!path || path.startsWith("-")) continue;
    files.push({
      path,
      status: xy.trim() || xy,
      staged: xy[0] !== " " && xy[0] !== "?",
      unstaged: xy[1] !== " " || xy[0] === "?",
    });
    if (files.length >= MAX_STATUS_FILES) break;
  }
  return files;
}

export function parseAheadBehind(raw: string): { ahead: number; behind: number } {
  // "{ahead}\t{behind}" from rev-list --left-right --count
  const parts = raw.trim().split(/\s+/);
  const ahead = Number(parts[0] ?? 0) || 0;
  const behind = Number(parts[1] ?? 0) || 0;
  return { ahead, behind };
}

export function makeStatusToken(parts: {
  branch: string;
  upstream: string | null;
  ahead: number;
  behind: number;
  files: ChangedFile[];
}): string {
  const payload = JSON.stringify({
    branch: parts.branch,
    upstream: parts.upstream,
    ahead: parts.ahead,
    behind: parts.behind,
    files: parts.files.map((f) => `${f.status}:${f.path}`).sort(),
  });
  return createHash("sha256").update(payload).digest("hex").slice(0, 24);
}

function isInsideRoot(candidate: string, root: string): boolean {
  const c = candidate.toLowerCase();
  const r = root.toLowerCase();
  return c === r || c.startsWith(r.endsWith(sep) ? r : r + sep);
}

function assertSafeRelPath(rel: string): void {
  if (!rel || rel.startsWith("-") || rel.includes("\0")) {
    throw new RepoError("invalid_path", "unsafe_path");
  }
  if (rel.includes("..") || rel.startsWith("/") || /^[a-zA-Z]:/.test(rel)) {
    throw new RepoError("invalid_path", "path_escape");
  }
  if (rel.startsWith("\\\\") || rel.startsWith("//")) {
    throw new RepoError("invalid_path", "unc_rejected");
  }
}

export async function runProcess(
  bin: string,
  args: string[],
  opts: {
    cwd: string;
    timeoutMs?: number;
    env?: NodeJS.ProcessEnv;
    maxStdout?: number;
  },
): Promise<ProcResult> {
  for (const a of args) {
    if (typeof a !== "string") throw new RepoError("invalid_args", "non_string_arg");
  }
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const maxStdout = opts.maxStdout ?? MAX_STDOUT;
  // Keep a minimal env, but include the Windows profile vars `gh` needs to
  // read its keyring login (APPDATA / LOCALAPPDATA). Without those, spawned
  // `gh repo create` fails with "please run: gh auth login" even when the
  // interactive shell is already authenticated.
  const env: NodeJS.ProcessEnv = {
    PATH: process.env.PATH,
    SystemRoot: process.env.SystemRoot,
    USERPROFILE: process.env.USERPROFILE,
    HOME: process.env.HOME,
    USERNAME: process.env.USERNAME,
    USERDOMAIN: process.env.USERDOMAIN,
    APPDATA: process.env.APPDATA,
    LOCALAPPDATA: process.env.LOCALAPPDATA,
    LANG: process.env.LANG ?? "C",
    GIT_TERMINAL_PROMPT: "0",
    GIT_OPTIONAL_LOCKS: "0",
    GH_PROMPT_DISABLED: "1",
    GH_NO_UPDATE_NOTIFIER: "1",
    // Optional explicit tokens (preferred when set; otherwise gh uses keyring).
    ...(process.env.GH_TOKEN ? { GH_TOKEN: process.env.GH_TOKEN } : {}),
    ...(process.env.GITHUB_TOKEN ? { GITHUB_TOKEN: process.env.GITHUB_TOKEN } : {}),
    ...opts.env,
  };
  // Strip credential helpers that might prompt; keep GH token auth via gh itself.
  delete env.GIT_ASKPASS;
  delete env.SSH_ASKPASS;

  return new Promise((resolvePromise, rejectPromise) => {
    let stdout = "";
    let stderr = "";
    let truncated = false;
    const child = spawn(bin, args, {
      cwd: opts.cwd,
      shell: false,
      env,
      windowsHide: true,
    });
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      rejectPromise(new RepoError("timeout", `process_timeout_${timeoutMs}ms`, 504));
    }, timeoutMs);

    child.stdout.on("data", (d: Buffer) => {
      if (stdout.length >= maxStdout) {
        truncated = true;
        return;
      }
      stdout += d.toString("utf8");
      if (stdout.length > maxStdout) {
        stdout = stdout.slice(0, maxStdout);
        truncated = true;
      }
    });
    child.stderr.on("data", (d: Buffer) => {
      if (stderr.length < 64_000) stderr += d.toString("utf8");
    });
    child.on("error", (e) => {
      clearTimeout(timer);
      rejectPromise(
        (e as NodeJS.ErrnoException).code === "ENOENT"
          ? new RepoError("tool_missing", `binary_not_found:${bin}`, 500)
          : e,
      );
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolvePromise({ code: code ?? -1, stdout, stderr, truncated });
    });
  });
}

export class RepoService {
  readonly roots: RootEntry[];
  private selectedId: string | null = null;
  private readonly locks = new Map<string, Promise<void>>();
  private readonly gitBin: string | null;
  private readonly ghBin: string | null;
  private discoverCache: { at: number; repos: RepoSummary[] } | null = null;
  private static readonly DISCOVER_CACHE_MS = 5_000;

  constructor(opts?: {
    rootsEnv?: string;
    defaultWorkdir?: string;
    gitBin?: string | null;
    ghBin?: string | null;
  }) {
    const defaultWorkdir = opts?.defaultWorkdir ?? process.env.NOVA_BRIDGE_WORKDIR ?? process.cwd();
    this.roots = parseRepoRoots(opts?.rootsEnv ?? process.env.NOVA_REPO_ROOTS, defaultWorkdir);
    this.gitBin = opts?.gitBin === undefined ? resolveGitBin() : opts.gitBin;
    this.ghBin = opts?.ghBin === undefined ? resolveGhBin() : opts.ghBin;

    // Prefer selecting the default workdir repo if it is a git root.
    try {
      const cwd = realpathSync(pathResolve(defaultWorkdir));
      if (existsSync(join(cwd, ".git"))) {
        this.selectedId = opaqueRepoId(cwd);
      }
    } catch {
      /* ignore */
    }
  }

  private invalidateDiscoverCache(): void {
    this.discoverCache = null;
  }

  private summaryForPath(canon: string, root: RootEntry): RepoSummary {
    const id = opaqueRepoId(canon);
    const rel =
      canon.toLowerCase() === root.path.toLowerCase()
        ? "."
        : canon.slice(root.path.length).replace(/^[\\/]/, "");
    return {
      id,
      name: basename(canon),
      relativePath: rel.split(sep).join("/"),
      rootLabel: root.label,
      selected: this.selectedId === id,
    };
  }

  private isSkippableDir(name: string): boolean {
    return SKIP_DIR_NAMES.has(name) || name.startsWith(".");
  }

  readiness() {
    const tools = toolReadiness();
    return {
      ...tools,
      gitBin: this.gitBin ?? tools.gitBin,
      ghBin: this.ghBin ?? tools.ghBin,
      gitReady: Boolean(this.gitBin),
      ghReady: Boolean(this.ghBin),
      rootCount: this.roots.length,
    };
  }

  private requireGit(): string {
    if (!this.gitBin) throw new RepoError("tool_missing", "git_not_found", 500);
    return this.gitBin;
  }

  private requireGh(): string {
    if (!this.ghBin) throw new RepoError("tool_missing", "gh_not_found", 500);
    return this.ghBin;
  }

  private async withLock<T>(repoId: string, fn: () => Promise<T>): Promise<T> {
    const prev = this.locks.get(repoId) ?? Promise.resolve();
    let release!: () => void;
    const done = new Promise<void>((r) => {
      release = r;
    });
    this.locks.set(
      repoId,
      prev.then(() => done),
    );
    await prev;
    try {
      return await fn();
    } finally {
      release();
    }
  }

  resolveRepo(repoId: string): { id: string; path: string; name: string; root: RootEntry } {
    const id = repoId.trim();
    if (!/^[a-f0-9]{16}$/.test(id)) {
      throw new RepoError("not_found", "unknown_repo", 404);
    }
    for (const root of this.roots) {
      const hit = this.findByIdUnder(root.path, id, 0);
      if (hit) {
        return { id, path: hit, name: basename(hit), root };
      }
    }
    throw new RepoError("not_found", "unknown_repo", 404);
  }

  private findByIdUnder(dir: string, id: string, depth: number): string | null {
    // Shallow only: allowlisted root + immediate children (avoids Dropbox deep walks).
    if (depth > 1) return null;
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return null;
    }
    if (entries.includes(".git")) {
      try {
        const canon = realpathSync(dir);
        if (opaqueRepoId(canon) === id && this.isUnderAnyRoot(canon)) return canon;
      } catch {
        return null;
      }
      return null;
    }
    if (depth >= 1) return null;
    for (const name of entries) {
      if (this.isSkippableDir(name)) continue;
      const child = join(dir, name);
      try {
        const st = lstatSync(child);
        if (!st.isDirectory() || st.isSymbolicLink()) continue;
        if (!existsSync(join(child, ".git"))) continue;
        const real = realpathSync(child);
        if (!this.isUnderAnyRoot(real)) continue;
        if (opaqueRepoId(real) === id) return real;
      } catch {
        continue;
      }
    }
    return null;
  }

  private isUnderAnyRoot(canonical: string): boolean {
    return this.roots.some((r) => isInsideRoot(canonical, r.path));
  }

  private canonicalUnderRoots(candidate: string): string {
    let canonical: string;
    try {
      canonical = realpathSync(pathResolve(candidate));
    } catch {
      throw new RepoError("path_escape", "cannot_resolve_path", 400);
    }
    if (!this.isUnderAnyRoot(canonical)) {
      throw new RepoError("path_escape", "outside_allowlisted_roots", 403);
    }
    return canonical;
  }

  private discoverSync(): RepoSummary[] {
    const now = Date.now();
    if (
      this.discoverCache &&
      now - this.discoverCache.at < RepoService.DISCOVER_CACHE_MS
    ) {
      return this.discoverCache.repos.map((r) => ({
        ...r,
        selected: this.selectedId === r.id,
      }));
    }
    const out: RepoSummary[] = [];
    const seen = new Set<string>();
    for (const root of this.roots) {
      this.walkRepos(root, root.path, 0, out, seen);
    }
    out.sort((a, b) => a.name.localeCompare(b.name));
    this.discoverCache = { at: now, repos: out };
    return out.map((r) => ({ ...r, selected: this.selectedId === r.id }));
  }

  private walkRepos(
    root: RootEntry,
    dir: string,
    depth: number,
    out: RepoSummary[],
    seen: Set<string>,
  ): void {
    // Only the allowlisted root and its immediate children — never deep-walk
    // Dropbox / large trees (that blocked the Node event loop and timed out the phone).
    if (depth > 1) return;
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return;
    }
    if (entries.includes(".git")) {
      try {
        const canon = realpathSync(dir);
        if (!isInsideRoot(canon, root.path)) return;
        const id = opaqueRepoId(canon);
        if (seen.has(id)) return;
        seen.add(id);
        out.push(this.summaryForPath(canon, root));
      } catch {
        /* skip */
      }
      return;
    }
    if (depth >= 1) return;
    for (const name of entries) {
      if (this.isSkippableDir(name)) continue;
      const child = join(dir, name);
      try {
        const st = lstatSync(child);
        // Skip junctions/symlinks (Dropbox placeholders) and non-dirs.
        if (!st.isDirectory() || st.isSymbolicLink()) continue;
        if (!existsSync(join(child, ".git"))) continue;
        const real = realpathSync(child);
        if (!isInsideRoot(real, root.path)) continue;
        const id = opaqueRepoId(real);
        if (seen.has(id)) continue;
        seen.add(id);
        out.push(this.summaryForPath(real, root));
      } catch {
        continue;
      }
    }
  }

  listRepos(): { repos: RepoSummary[]; selectedRepoId: string | null } {
    const repos = this.discoverSync();
    if (this.selectedId && !repos.some((r) => r.id === this.selectedId)) {
      this.selectedId = null;
    }
    return { repos, selectedRepoId: this.selectedId };
  }

  selectRepo(repoId: string): RepoSummary {
    const resolved = this.resolveRepo(repoId);
    this.selectedId = resolved.id;
    this.invalidateDiscoverCache();
    return { ...this.summaryForPath(resolved.path, resolved.root), selected: true };
  }

  selectedPath(): string | null {
    if (!this.selectedId) return null;
    try {
      return this.resolveRepo(this.selectedId).path;
    } catch {
      return null;
    }
  }

  resolveCwd(repoId?: string | null, legacyCwd?: string | null): string {
    if (repoId) {
      return this.resolveRepo(repoId).path;
    }
    const selected = this.selectedPath();
    if (selected) return selected;
    // Compatibility: allow legacy cwd only if it resolves under allowlisted roots.
    if (legacyCwd && legacyCwd.trim()) {
      return this.canonicalUnderRoots(legacyCwd.trim());
    }
    if (this.roots[0]) return this.roots[0].path;
    return process.cwd();
  }

  async clone(url: string, rootLabel?: string): Promise<RepoSummary> {
    const git = this.requireGit();
    const parsed = validateGitHubHttpsUrl(url);
    const root =
      (rootLabel
        ? this.roots.find((r) => r.label === rootLabel)
        : null) ?? this.roots[0];
    if (!root) throw new RepoError("no_roots", "no_allowlisted_roots", 500);

    const dest = join(root.path, parsed.repo);
    if (existsSync(dest)) {
      const canon = this.canonicalUnderRoots(dest);
      if (existsSync(join(canon, ".git"))) {
        this.selectedId = opaqueRepoId(canon);
        this.invalidateDiscoverCache();
        return { ...this.summaryForPath(canon, root), selected: true };
      }
      throw new RepoError("clone_conflict", "destination_exists", 409);
    }

    // Prefer `gh repo clone` so private repos use the PC's existing GitHub CLI login
    // instead of an interactive git credential prompt (which can hang until timeout).
    let result: ProcResult;
    if (this.ghBin) {
      result = await runProcess(
        this.ghBin,
        ["repo", "clone", `${parsed.owner}/${parsed.repo}`, dest, "--"],
        { cwd: root.path, timeoutMs: CLONE_TIMEOUT_MS },
      );
    } else {
      result = await runProcess(
        git,
        ["clone", "--", parsed.url, dest],
        { cwd: root.path, timeoutMs: CLONE_TIMEOUT_MS },
      );
    }
    if (result.code !== 0) {
      throw new RepoError(
        "clone_failed",
        result.stderr.trim().slice(0, 400) || "git_clone_failed",
        502,
      );
    }
    const canon = this.canonicalUnderRoots(dest);
    this.selectedId = opaqueRepoId(canon);
    this.invalidateDiscoverCache();
    return { ...this.summaryForPath(canon, root), selected: true };
  }

  async status(repoId: string): Promise<RepoStatus> {
    return this.withLock(repoId, async () => {
      const git = this.requireGit();
      const repo = this.resolveRepo(repoId);
      const branchRes = await runProcess(git, ["rev-parse", "--abbrev-ref", "HEAD"], {
        cwd: repo.path,
      });
      if (branchRes.code !== 0) {
        throw new RepoError("git_failed", branchRes.stderr.trim() || "rev_parse_failed", 502);
      }
      const branch = branchRes.stdout.trim() || "HEAD";

      let upstream: string | null = null;
      const upRes = await runProcess(
        git,
        ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
        { cwd: repo.path },
      );
      if (upRes.code === 0) upstream = upRes.stdout.trim() || null;

      let ahead = 0;
      let behind = 0;
      if (upstream) {
        const ab = await runProcess(
          git,
          ["rev-list", "--left-right", "--count", "HEAD...@{u}"],
          { cwd: repo.path },
        );
        if (ab.code === 0) {
          const parsed = parseAheadBehind(ab.stdout);
          ahead = parsed.ahead;
          behind = parsed.behind;
        }
      }

      const st = await runProcess(
        git,
        ["status", "--porcelain=v1", "-uall"],
        { cwd: repo.path },
      );
      if (st.code !== 0) {
        throw new RepoError("git_failed", st.stderr.trim() || "status_failed", 502);
      }
      const changedFiles = parsePorcelainStatus(st.stdout);
      const statusToken = makeStatusToken({
        branch,
        upstream,
        ahead,
        behind,
        files: changedFiles,
      });
      return {
        repoId: repo.id,
        name: repo.name,
        branch,
        upstream,
        ahead,
        behind,
        clean: changedFiles.length === 0,
        changedFiles,
        statusToken,
      };
    });
  }

  async diff(repoId: string): Promise<RepoDiff> {
    return this.withLock(repoId, async () => {
      const git = this.requireGit();
      const repo = this.resolveRepo(repoId);
      const status = await this.statusUnlocked(repo.path, repo.id, repo.name);
      const unstaged = await runProcess(git, ["diff", "--no-ext-diff", "--"], {
        cwd: repo.path,
        maxStdout: MAX_DIFF,
      });
      const staged = await runProcess(git, ["diff", "--cached", "--no-ext-diff", "--"], {
        cwd: repo.path,
        maxStdout: MAX_DIFF,
      });
      const untrackedList = status.changedFiles
        .filter((f) => f.status.includes("?"))
        .map((f) => f.path);

      let combined = "";
      if (staged.stdout) combined += staged.stdout;
      if (unstaged.stdout) {
        if (combined) combined += "\n";
        combined += unstaged.stdout;
      }
      if (untrackedList.length) {
        combined += `\n# untracked files (${untrackedList.length}):\n`;
        for (const p of untrackedList.slice(0, 50)) {
          combined += `#   ${p}\n`;
        }
      }
      const truncated =
        staged.truncated ||
        unstaged.truncated ||
        combined.length >= MAX_DIFF ||
        untrackedList.length > 50;
      if (combined.length > MAX_DIFF) combined = combined.slice(0, MAX_DIFF);

      return {
        repoId: repo.id,
        diff: combined,
        truncated,
        statusToken: status.statusToken,
      };
    });
  }

  private async statusUnlocked(
    path: string,
    repoId: string,
    name: string,
  ): Promise<RepoStatus> {
    const git = this.requireGit();
    const branchRes = await runProcess(git, ["rev-parse", "--abbrev-ref", "HEAD"], {
      cwd: path,
    });
    const branch = branchRes.stdout.trim() || "HEAD";
    let upstream: string | null = null;
    const upRes = await runProcess(
      git,
      ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
      { cwd: path },
    );
    if (upRes.code === 0) upstream = upRes.stdout.trim() || null;
    let ahead = 0;
    let behind = 0;
    if (upstream) {
      const ab = await runProcess(
        git,
        ["rev-list", "--left-right", "--count", "HEAD...@{u}"],
        { cwd: path },
      );
      if (ab.code === 0) {
        const parsed = parseAheadBehind(ab.stdout);
        ahead = parsed.ahead;
        behind = parsed.behind;
      }
    }
    const st = await runProcess(
      git,
      ["status", "--porcelain=v1", "-uall"],
      { cwd: path },
    );
    const changedFiles = parsePorcelainStatus(st.stdout);
    return {
      repoId,
      name,
      branch,
      upstream,
      ahead,
      behind,
      clean: changedFiles.length === 0,
      changedFiles,
      statusToken: makeStatusToken({ branch, upstream, ahead, behind, files: changedFiles }),
    };
  }

  async publish(repoId: string, req: PublishRequest): Promise<PublishResult> {
    return this.withLock(repoId, async () => {
      const git = this.requireGit();
      const repo = this.resolveRepo(repoId);

      const commitMessage = (req.commitMessage ?? "").trim();
      const prTitle = (req.prTitle ?? "").trim();
      if (!commitMessage) throw new RepoError("invalid_publish", "missing_commit_message");
      if (!prTitle) throw new RepoError("invalid_publish", "missing_pr_title");
      if (commitMessage.startsWith("-") || prTitle.startsWith("-")) {
        throw new RepoError("invalid_publish", "leading_option_rejected");
      }

      const current = await this.statusUnlocked(repo.path, repo.id, repo.name);
      if (!req.statusToken || req.statusToken !== current.statusToken) {
        throw new RepoError("stale_status", "status_token_mismatch", 409);
      }
      if (current.clean) {
        throw new RepoError("nothing_to_publish", "working_tree_clean", 400);
      }

      // Validate review token / tree before requiring GitHub CLI so stale
      // clients get a clear 409 even when gh is temporarily unavailable.
      const gh = this.requireGh();

      const defaultBranchRes = await runProcess(
        git,
        ["symbolic-ref", "refs/remotes/origin/HEAD"],
        { cwd: repo.path },
      );
      let defaultBranch = "main";
      if (defaultBranchRes.code === 0) {
        const ref = defaultBranchRes.stdout.trim();
        const m = ref.match(/refs\/remotes\/origin\/(.+)$/);
        if (m?.[1]) defaultBranch = m[1];
      }

      const branchSlug =
        (req.branchName && req.branchName.trim()) ||
        `fix-${new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)}`;
      const branch = sanitizeBranchSlug(branchSlug);
      if (branch === defaultBranch || branch === "main" || branch === "master") {
        throw new RepoError("invalid_branch", "cannot_publish_to_default_branch");
      }

      // Create / switch branch (never force)
      const curBranch = current.branch;
      if (curBranch !== branch) {
        const create = await runProcess(git, ["checkout", "-B", branch], {
          cwd: repo.path,
        });
        if (create.code !== 0) {
          throw new RepoError(
            "branch_failed",
            create.stderr.trim().slice(0, 400) || "checkout_failed",
            502,
          );
        }
      }

      const paths = req.paths?.length ? req.paths : current.changedFiles.map((f) => f.path);
      for (const p of paths) assertSafeRelPath(p);
      if (!paths.length) throw new RepoError("nothing_to_publish", "no_paths");

      const add = await runProcess(git, ["add", "--", ...paths], { cwd: repo.path });
      if (add.code !== 0) {
        throw new RepoError("stage_failed", add.stderr.trim().slice(0, 400) || "git_add_failed", 502);
      }

      const commit = await runProcess(
        git,
        ["commit", "-m", commitMessage, "--no-verify"],
        {
          cwd: repo.path,
          env: {
            GIT_AUTHOR_NAME: process.env.GIT_AUTHOR_NAME ?? "Nova Bridge",
            GIT_AUTHOR_EMAIL: process.env.GIT_AUTHOR_EMAIL ?? "nova-bridge@local",
            GIT_COMMITTER_NAME: process.env.GIT_COMMITTER_NAME ?? "Nova Bridge",
            GIT_COMMITTER_EMAIL: process.env.GIT_COMMITTER_EMAIL ?? "nova-bridge@local",
          },
        },
      );
      if (commit.code !== 0) {
        throw new RepoError(
          "commit_failed",
          commit.stderr.trim().slice(0, 400) || "git_commit_failed",
          502,
        );
      }

      const shaRes = await runProcess(git, ["rev-parse", "HEAD"], { cwd: repo.path });
      const commitSha = shaRes.stdout.trim();

      const push = await runProcess(
        git,
        ["push", "-u", "origin", branch, "--"],
        { cwd: repo.path, timeoutMs: PUBLISH_TIMEOUT_MS },
      );
      if (push.code !== 0) {
        throw new RepoError(
          "push_failed",
          push.stderr.trim().slice(0, 400) || "git_push_failed",
          502,
        );
      }

      const prBody = (req.prBody ?? "").trim() || commitMessage;
      const pr = await runProcess(
        gh,
        [
          "pr",
          "create",
          "--title",
          prTitle,
          "--body",
          prBody,
          "--head",
          branch,
          "--base",
          defaultBranch,
        ],
        { cwd: repo.path, timeoutMs: PUBLISH_TIMEOUT_MS },
      );
      if (pr.code !== 0) {
        throw new RepoError(
          "pr_failed",
          pr.stderr.trim().slice(0, 400) || "gh_pr_create_failed",
          502,
        );
      }
      const prUrl = extractPrUrl(pr.stdout + "\n" + pr.stderr);
      if (!prUrl) {
        throw new RepoError("pr_failed", "pr_url_missing", 502);
      }
      const numMatch = prUrl.match(/\/pull\/(\d+)/);
      return {
        repoId: repo.id,
        branch,
        commitSha,
        prUrl,
        prNumber: numMatch ? Number(numMatch[1]) : null,
      };
    });
  }

  async createPublicWebProject(
    request: CreateProjectRequest,
  ): Promise<CreateProjectResult> {
    const git = this.requireGit();
    const gh = this.requireGh();
    const name = validateProjectName(request.name);
    const template = validateWebProjectTemplate(request.template);
    const description = (request.description ?? "").trim().slice(0, 350);
    if (description.startsWith("-")) {
      throw new RepoError("invalid_description", "leading_option_rejected");
    }
    const root =
      (request.rootLabel
        ? this.roots.find((entry) => entry.label === request.rootLabel)
        : null) ?? this.roots[0];
    if (!root) throw new RepoError("no_roots", "no_allowlisted_roots", 500);

    const destination = join(root.path, name);
    if (existsSync(destination)) {
      throw new RepoError("project_exists", "local_destination_exists", 409);
    }

    mkdirSync(destination, { recursive: false });
    try {
      scaffoldWebProject(destination, name, template);

      const commands: string[][] = [
        ["init", "-b", "main"],
        ["add", "--", "."],
        ["commit", "-m", `Initial ${template} web project`, "--no-verify"],
      ];
      for (const args of commands) {
        const result = await runProcess(git, args, {
          cwd: destination,
          env: {
            GIT_AUTHOR_NAME: process.env.GIT_AUTHOR_NAME ?? "Nova Bridge",
            GIT_AUTHOR_EMAIL:
              process.env.GIT_AUTHOR_EMAIL ?? "nova-bridge@local",
            GIT_COMMITTER_NAME:
              process.env.GIT_COMMITTER_NAME ?? "Nova Bridge",
            GIT_COMMITTER_EMAIL:
              process.env.GIT_COMMITTER_EMAIL ?? "nova-bridge@local",
          },
        });
        if (result.code !== 0) {
          throw new RepoError(
            "project_init_failed",
            result.stderr.trim().slice(0, 400) || `git_${args[0]}_failed`,
            502,
          );
        }
      }

      const ghArgs = [
        "repo",
        "create",
        name,
        "--public",
        "--source",
        destination,
        "--remote",
        "origin",
        "--push",
      ];
      if (description) ghArgs.push("--description", description);
      const created = await runProcess(gh, ghArgs, {
        cwd: destination,
        timeoutMs: PUBLISH_TIMEOUT_MS,
      });
      if (created.code !== 0) {
        throw new RepoError(
          "github_repo_create_failed",
          created.stderr.trim().slice(0, 500) || "gh_repo_create_failed",
          502,
        );
      }

      const repoUrlMatch = (
        created.stdout +
        "\n" +
        created.stderr
      ).match(/https:\/\/github\.com\/[\w.-]+\/[\w.-]+/);
      const remote = await runProcess(
        git,
        ["remote", "get-url", "origin"],
        { cwd: destination },
      );
      const repoUrl =
        repoUrlMatch?.[0] ??
        remote.stdout.trim().replace(/\.git$/i, "") ??
        "";
      if (!repoUrl.startsWith("https://github.com/")) {
        throw new RepoError(
          "github_repo_create_failed",
          "created_repo_url_missing",
          502,
        );
      }

      const canonical = this.canonicalUnderRoots(destination);
      this.selectedId = opaqueRepoId(canonical);
      this.invalidateDiscoverCache();
      const repo = {
        ...this.summaryForPath(canonical, root),
        selected: true,
      };
      return {
        repo,
        repoUrl,
        template,
        selectedRepoId: repo.id,
      };
    } catch (error) {
      // Remove only the newly-created local directory. A remote created just
      // before an unexpected response is intentionally not deleted.
      try {
        rmSync(destination, { recursive: true, force: true });
      } catch {
        /* best effort */
      }
      throw error;
    }
  }
}

export function extractPrUrl(text: string): string | null {
  const m = text.match(/https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+/);
  return m?.[0] ?? null;
}

export function timingSafeTokenEqual(provided: string, expected: string): boolean {
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

function writeProjectFile(root: string, relativePath: string, content: string): void {
  const destination = join(root, relativePath);
  mkdirSync(dirname(destination), { recursive: true });
  writeFileSync(destination, content, "utf8");
}

export function scaffoldWebProject(
  root: string,
  name: string,
  template: WebProjectTemplate,
): void {
  const title = name
    .split(/[-_.]+/)
    .filter(Boolean)
    .map((part) => part[0]!.toUpperCase() + part.slice(1))
    .join(" ");
  const commonReadme = `# ${title}\n\nCreated from Nova's ${template} web template.\n`;

  writeProjectFile(root, "README.md", commonReadme);
  writeProjectFile(root, ".gitignore", "node_modules/\ndist/\n.next/\n.env*\n!.env.example\n");

  if (template === "static") {
    writeProjectFile(
      root,
      "index.html",
      `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta name="description" content="${title}" />
    <title>${title}</title>
    <link rel="stylesheet" href="styles.css" />
  </head>
  <body>
    <main class="hero">
      <p class="eyebrow">New project</p>
      <h1>${title}</h1>
      <p>Start designing your next web experience.</p>
      <button id="cta" type="button">Get started</button>
    </main>
    <script src="script.js"></script>
  </body>
</html>
`,
    );
    writeProjectFile(
      root,
      "styles.css",
      `:root { font-family: Inter, system-ui, sans-serif; color: #f8fafc; background: #09090b; }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; }
.hero { width: min(680px, 90vw); padding: 4rem; border: 1px solid #27272a; border-radius: 24px; background: #18181b; }
.eyebrow { color: #a78bfa; text-transform: uppercase; letter-spacing: .14em; font-size: .75rem; }
h1 { margin: .5rem 0 1rem; font-size: clamp(3rem, 10vw, 6rem); line-height: .9; }
p { color: #a1a1aa; font-size: 1.1rem; }
button { margin-top: 1rem; padding: .85rem 1.2rem; border: 0; border-radius: 999px; background: #8b5cf6; color: white; font-weight: 700; cursor: pointer; }
`,
    );
    writeProjectFile(
      root,
      "script.js",
      `document.querySelector("#cta")?.addEventListener("click", () => {
  document.querySelector("#cta").textContent = "Ready to build";
});
`,
    );
    return;
  }

  if (template === "vite") {
    writeProjectFile(
      root,
      "package.json",
      JSON.stringify(
        {
          name,
          private: true,
          version: "0.1.0",
          type: "module",
          scripts: { dev: "vite", build: "vite build", preview: "vite preview" },
          devDependencies: { vite: "^7.0.0" },
        },
        null,
        2,
      ) + "\n",
    );
    writeProjectFile(
      root,
      "index.html",
      `<!doctype html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>${title}</title></head><body><div id="app"></div><script type="module" src="/src/main.js"></script></body></html>\n`,
    );
    writeProjectFile(
      root,
      "src/main.js",
      `import "./style.css";
document.querySelector("#app").innerHTML = \`
  <main><span>Vite starter</span><h1>${title}</h1><p>Design fast. Ship thoughtfully.</p></main>
\`;
`,
    );
    writeProjectFile(
      root,
      "src/style.css",
      `:root { font-family: Inter, system-ui, sans-serif; color: #18181b; background: #fafafa; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; }
main { width: min(720px, 88vw); } span { color: #7c3aed; font-weight: 700; }
h1 { font-size: clamp(3rem, 12vw, 7rem); margin: .4rem 0; line-height: .9; }
p { color: #71717a; font-size: 1.25rem; }
`,
    );
    return;
  }

  if (template === "react-vite") {
    writeProjectFile(
      root,
      "package.json",
      JSON.stringify(
        {
          name,
          private: true,
          version: "0.1.0",
          type: "module",
          scripts: {
            dev: "vite",
            build: "vite build",
            lint: "eslint .",
            preview: "vite preview",
          },
          dependencies: { react: "^19.1.0", "react-dom": "^19.1.0" },
          devDependencies: {
            "@vitejs/plugin-react": "^4.6.0",
            vite: "^7.0.0",
          },
        },
        null,
        2,
      ) + "\n",
    );
    writeProjectFile(
      root,
      "index.html",
      `<!doctype html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>${title}</title></head><body><div id="root"></div><script type="module" src="/src/main.jsx"></script></body></html>\n`,
    );
    writeProjectFile(
      root,
      "vite.config.js",
      `import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
export default defineConfig({ plugins: [react()] });
`,
    );
    writeProjectFile(
      root,
      "src/main.jsx",
      `import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App.jsx";
import "./styles.css";
createRoot(document.getElementById("root")).render(<StrictMode><App /></StrictMode>);
`,
    );
    writeProjectFile(
      root,
      "src/App.jsx",
      `export default function App() {
  return <main><span>React starter</span><h1>${title}</h1><p>Build a polished web experience.</p><button>Start designing</button></main>;
}
`,
    );
    writeProjectFile(
      root,
      "src/styles.css",
      `:root { font-family: Inter, system-ui, sans-serif; color: #f4f4f5; background: #09090b; }
* { box-sizing: border-box; } body { margin: 0; min-height: 100vh; display: grid; place-items: center; }
main { width: min(760px, 90vw); padding: 4rem; background: linear-gradient(145deg,#18181b,#27272a); border-radius: 28px; }
span { color: #c4b5fd; font-weight: 700; } h1 { font-size: clamp(3rem,10vw,7rem); line-height: .9; margin: .5rem 0 1.5rem; }
p { color: #a1a1aa; font-size: 1.2rem; } button { padding: .9rem 1.3rem; border: 0; border-radius: 999px; color: white; background: #7c3aed; font-weight: 700; }
`,
    );
    return;
  }

  writeProjectFile(
    root,
    "package.json",
    JSON.stringify(
      {
        name,
        private: true,
        version: "0.1.0",
        scripts: {
          dev: "next dev",
          build: "next build",
          start: "next start",
          lint: "next lint",
        },
        dependencies: { next: "^15.4.0", react: "^19.1.0", "react-dom": "^19.1.0" },
        devDependencies: {
          "@types/node": "^22.0.0",
          "@types/react": "^19.0.0",
          typescript: "^5.8.0",
        },
      },
      null,
      2,
    ) + "\n",
  );
  writeProjectFile(root, "next.config.ts", `import type { NextConfig } from "next";\nconst config: NextConfig = {};\nexport default config;\n`);
  writeProjectFile(
    root,
    "tsconfig.json",
    JSON.stringify(
      {
        compilerOptions: {
          target: "ES2017",
          lib: ["dom", "dom.iterable", "esnext"],
          strict: true,
          noEmit: true,
          module: "esnext",
          moduleResolution: "bundler",
          jsx: "preserve",
          incremental: true,
          plugins: [{ name: "next" }],
          paths: { "@/*": ["./*"] },
        },
        include: ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
        exclude: ["node_modules"],
      },
      null,
      2,
    ) + "\n",
  );
  writeProjectFile(root, "next-env.d.ts", `/// <reference types="next" />\n/// <reference types="next/image-types/global" />\n`);
  writeProjectFile(
    root,
    "app/layout.tsx",
    `import type { Metadata } from "next";
import "./globals.css";
export const metadata: Metadata = { title: "${title}", description: "${title} website" };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
`,
  );
  writeProjectFile(
    root,
    "app/page.tsx",
    `export default function Home() {
  return <main><span>Next.js starter</span><h1>${title}</h1><p>Build an exceptional web experience.</p><button>Start designing</button></main>;
}
`,
  );
  writeProjectFile(
    root,
    "app/globals.css",
    `:root { font-family: Inter, Arial, sans-serif; color: #171717; background: #f5f5f4; }
* { box-sizing: border-box; } body { margin: 0; min-height: 100vh; display: grid; place-items: center; }
main { width: min(800px, 90vw); } span { color: #2563eb; font-weight: 700; }
h1 { font-size: clamp(3rem,10vw,7rem); line-height: .9; margin: .5rem 0 1.5rem; }
p { color: #57534e; font-size: 1.25rem; } button { padding: .9rem 1.3rem; border: 0; border-radius: 999px; color: white; background: #2563eb; font-weight: 700; }
`,
  );
}
