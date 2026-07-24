import { createHash, timingSafeEqual } from "node:crypto";
import { spawn } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join, resolve as pathResolve, sep } from "node:path";
import { BaselineService, type AgentReview } from "./baseline-service.js";
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
const MAX_CODE_FILE_BYTES = 256_000;
const MAX_CODE_SEARCH_FILES = 4_000;
const MAX_CODE_SEARCH_ENTRIES = 20_000;
const MAX_CODE_SEARCH_MATCHES = 5_000;
const MAX_CODE_SEARCH_RESULTS = 24;
const MAX_CODE_READ_LINES = 240;
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

export type RepoFileEntry = {
  name: string;
  path: string;
  kind: "file" | "directory";
  size?: number;
};

export type RepoFileListing = {
  repoId: string;
  path: string;
  entries: RepoFileEntry[];
};

export type CodeSearchMatch = {
  path: string;
  line: number;
  snippet: string;
  matchedTerms: string[];
};

export type CodeSearchResult = {
  repoId: string;
  repoName: string;
  query: string;
  matches: CodeSearchMatch[];
  truncated: boolean;
};

export type CodeReadResult = {
  repoId: string;
  repoName: string;
  path: string;
  startLine: number;
  endLine: number;
  totalLines: number;
  content: string;
  truncated: boolean;
};

export type ResolvedRepoPath = {
  repoId: string;
  repoPath: string;
  relativePath: string;
  absolutePath: string;
  name: string;
  kind: "file" | "directory";
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

export type CommitAndBuildRequest = {
  /** Optional; when set must match the Nova checkout status token. */
  statusToken?: string;
  commitMessage?: string;
  /**
   * When true, return after commit+push with `buildStatus: "building"` and a
   * `jobId` for polling. New phone clients set this so they do not hold one
   * HTTP socket open for the full 10–25 min CI wait.
   */
  asyncPoll?: boolean;
};

export type CommitAndBuildResult = {
  /** Background job id — phone polls GET /nova/commit-and-build/:jobId. */
  jobId: string;
  repoId: string;
  branch: string;
  commitSha: string;
  committed: boolean;
  pushed: boolean;
  /** Absolute path where SideStore expects the IPA. */
  ipaPath: string;
  /** Relative path from the Nova repo root. */
  ipaRelativePath: string;
  workflowRunId: string | null;
  buildStatus: "building" | "completed" | "failed";
  detail: string;
};

type IpaBuildJob = CommitAndBuildResult & {
  errorCode?: string;
  updatedAt: number;
};

const IPA_BUILD_TIMEOUT_MS = 45 * 60_000;
const IPA_JOB_TTL_MS = 2 * 60 * 60_000;

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

/** Ensure gh/git stay resolvable when the bridge was started with a thin PATH. */
function ensureWindowsToolsOnPath(pathEnv: string | undefined): string {
  const parts = (pathEnv ?? "").split(";").filter(Boolean);
  const extras = [
    process.env.ProgramFiles
      ? join(process.env.ProgramFiles, "GitHub CLI")
      : null,
    process.env.LOCALAPPDATA
      ? join(process.env.LOCALAPPDATA, "GitHubCLI", "bin")
      : null,
    process.env.ProgramFiles
      ? join(process.env.ProgramFiles, "Git", "bin")
      : null,
    process.env.ProgramFiles
      ? join(process.env.ProgramFiles, "Git", "cmd")
      : null,
  ].filter((p): p is string => Boolean(p));
  for (const extra of extras) {
    if (!parts.some((p) => p.toLowerCase() === extra.toLowerCase())) {
      parts.unshift(extra);
    }
  }
  return parts.join(";");
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
  // read its keyring login (APPDATA / LOCALAPPDATA) and the ProgramFiles*
  // vars PowerShell scripts use to locate `gh.exe` / `git.exe`. Without
  // ProgramFiles, run-ipa-ci.ps1's Find-Gh fails with "run 'gh auth login'"
  // even when the interactive shell is already authenticated.
  const pathWithTools = ensureWindowsToolsOnPath(process.env.PATH);
  const env: NodeJS.ProcessEnv = {
    PATH: pathWithTools,
    SystemRoot: process.env.SystemRoot,
    windir: process.env.windir ?? process.env.SystemRoot,
    SystemDrive: process.env.SystemDrive,
    USERPROFILE: process.env.USERPROFILE,
    HOME: process.env.HOME,
    HOMEDRIVE: process.env.HOMEDRIVE,
    HOMEPATH: process.env.HOMEPATH,
    USERNAME: process.env.USERNAME,
    USERDOMAIN: process.env.USERDOMAIN,
    APPDATA: process.env.APPDATA,
    LOCALAPPDATA: process.env.LOCALAPPDATA,
    TEMP: process.env.TEMP,
    TMP: process.env.TMP,
    ProgramFiles: process.env.ProgramFiles,
    ProgramW6432: process.env.ProgramW6432,
    "ProgramFiles(x86)": process.env["ProgramFiles(x86)"],
    ComSpec: process.env.ComSpec,
    // Without PATHEXT (.EXE;.CMD;...), PowerShell cannot launch gh/git and
    // $LASTEXITCODE stays $null — which `-ne 0` treats as failure.
    PATHEXT: process.env.PATHEXT,
    OS: process.env.OS,
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
  // Node spawn rejects / stringifies undefined env values poorly on Windows.
  for (const key of Object.keys(env)) {
    if (env[key] === undefined || env[key] === null) delete env[key];
  }

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
  private readonly baselines: BaselineService;
  /** Latest baseline id per repo (for publish defaults / review UI). */
  private readonly activeBaseline = new Map<string, string>();
  private discoverCache: { at: number; repos: RepoSummary[] } | null = null;
  private static readonly DISCOVER_CACHE_MS = 5_000;
  /** In-memory IPA commit-and-build jobs (survive phone HTTP disconnects). */
  private readonly ipaJobs = new Map<string, IpaBuildJob>();

  constructor(opts?: {
    rootsEnv?: string;
    defaultWorkdir?: string;
    gitBin?: string | null;
    ghBin?: string | null;
    baselineStateDir?: string;
  }) {
    const defaultWorkdir = opts?.defaultWorkdir ?? process.env.NOVA_BRIDGE_WORKDIR ?? process.cwd();
    this.roots = parseRepoRoots(opts?.rootsEnv ?? process.env.NOVA_REPO_ROOTS, defaultWorkdir);
    this.gitBin = opts?.gitBin === undefined ? resolveGitBin() : opts.gitBin;
    this.ghBin = opts?.ghBin === undefined ? resolveGhBin() : opts.ghBin;
    this.baselines = new BaselineService(opts?.baselineStateDir);

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

  /**
   * Resolve a phone-supplied relative path without permitting symlink/junction
   * escapes. Empty means the repository root.
   */
  resolveRepoPath(repoId: string, requestedPath?: string | null): ResolvedRepoPath {
    const repo = this.resolveRepo(repoId);
    const relativePath = (requestedPath ?? "").trim().replace(/\\/g, "/");
    if (relativePath) {
      assertSafeRelPath(relativePath);
      if (relativePath.split("/").some((part) => !part || part.startsWith("."))) {
        throw new RepoError("invalid_path", "hidden_path_rejected", 403);
      }
    }

    const candidate = relativePath
      ? pathResolve(repo.path, ...relativePath.split("/"))
      : repo.path;
    let absolutePath: string;
    try {
      absolutePath = realpathSync(candidate);
    } catch {
      throw new RepoError("not_found", "path_not_found", 404);
    }
    if (!isInsideRoot(absolutePath, repo.path)) {
      throw new RepoError("path_escape", "outside_repository", 403);
    }
    const stat = lstatSync(absolutePath);
    if (stat.isSymbolicLink() || (!stat.isDirectory() && !stat.isFile())) {
      throw new RepoError("invalid_path", "unsupported_path_type", 400);
    }
    return {
      repoId: repo.id,
      repoPath: repo.path,
      relativePath,
      absolutePath,
      name: relativePath ? basename(absolutePath) : repo.name,
      kind: stat.isDirectory() ? "directory" : "file",
    };
  }

  /** List one directory level for the mobile repository browser. */
  listFiles(repoId: string, requestedPath?: string | null): RepoFileListing {
    const resolved = this.resolveRepoPath(repoId, requestedPath);
    if (resolved.kind !== "directory") {
      throw new RepoError("invalid_path", "path_is_not_directory", 400);
    }
    const entries: RepoFileEntry[] = [];
    for (const name of readdirSync(resolved.absolutePath).sort((a, b) => a.localeCompare(b))) {
      if (name.startsWith(".") || this.isSkippableDir(name)) continue;
      const childPath = join(resolved.absolutePath, name);
      try {
        const stat = lstatSync(childPath);
        if (stat.isSymbolicLink()) continue;
        const kind = stat.isDirectory() ? "directory" : stat.isFile() ? "file" : null;
        if (!kind) continue;
        const relative = resolved.relativePath
          ? `${resolved.relativePath}/${name}`
          : name;
        entries.push({
          name,
          path: relative.replace(/\\/g, "/"),
          kind,
          ...(kind === "file" ? { size: stat.size } : {}),
        });
        if (entries.length >= 500) break;
      } catch {
        /* Dropbox placeholders can disappear while listing; skip them. */
      }
    }
    entries.sort((a, b) => {
      if (a.kind !== b.kind) return a.kind === "directory" ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
    return { repoId: resolved.repoId, path: resolved.relativePath, entries };
  }

  /**
   * Write a phone-uploaded file into the repository. Creates missing parent
   * directories under the repo only. Rejects escapes, hidden segments, and
   * oversized payloads.
   */
  writeFile(
    repoId: string,
    requestedPath: string,
    content: Buffer,
    opts?: { overwrite?: boolean },
  ): { repoId: string; path: string; size: number; created: boolean } {
    const MAX_UPLOAD_BYTES = 8 * 1024 * 1024;
    if (!Buffer.isBuffer(content)) {
      throw new RepoError("invalid_args", "content_required", 400);
    }
    if (content.length === 0) {
      throw new RepoError("invalid_args", "empty_file", 400);
    }
    if (content.length > MAX_UPLOAD_BYTES) {
      throw new RepoError("too_large", `max_${MAX_UPLOAD_BYTES}_bytes`, 413);
    }

    const repo = this.resolveRepo(repoId);
    const relativePath = (requestedPath ?? "").trim().replace(/\\/g, "/");
    if (!relativePath) {
      throw new RepoError("invalid_path", "missing_path", 400);
    }
    assertSafeRelPath(relativePath);
    const parts = relativePath.split("/");
    if (parts.some((part) => !part || part.startsWith("."))) {
      throw new RepoError("invalid_path", "hidden_path_rejected", 403);
    }

    const absolutePath = pathResolve(repo.path, ...parts);
    const parentAbs = dirname(absolutePath);
    let parentReal: string;
    try {
      parentReal = realpathSync(parentAbs);
    } catch {
      mkdirSync(parentAbs, { recursive: true });
      parentReal = realpathSync(parentAbs);
    }
    if (!isInsideRoot(parentReal, repo.path)) {
      throw new RepoError("path_escape", "outside_repository", 403);
    }
    const candidate = join(parentReal, basename(absolutePath));
    if (!isInsideRoot(candidate, repo.path)) {
      throw new RepoError("path_escape", "outside_repository", 403);
    }

    const overwrite = opts?.overwrite === true;
    const existed = existsSync(candidate);
    if (existed) {
      const st = lstatSync(candidate);
      if (st.isSymbolicLink() || st.isDirectory()) {
        throw new RepoError("invalid_path", "cannot_overwrite_directory", 400);
      }
      if (!overwrite) {
        throw new RepoError("already_exists", "file_exists", 409);
      }
    }

    writeFileSync(candidate, content);
    const written = realpathSync(candidate);
    if (!isInsideRoot(written, repo.path)) {
      try {
        rmSync(written, { force: true });
      } catch {
        /* best-effort cleanup */
      }
      throw new RepoError("path_escape", "outside_repository", 403);
    }

    return {
      repoId: repo.id,
      path: relativePath,
      size: content.length,
      created: !existed,
    };
  }

  /**
   * Locate Nova's own monorepo independently of the Coding-tab selection.
   * This prevents a user-selected project from becoming the source of truth for
   * questions such as "can Nova record video?".
   */
  resolveNovaRepo(): { id: string; path: string; name: string; root: RootEntry } {
    const candidates = this.discoverSync();
    for (const summary of candidates) {
      const repo = this.resolveRepo(summary.id);
      if (
        existsSync(join(repo.path, "Nova", "Package.swift")) &&
        existsSync(join(repo.path, "nova-bridge", "package.json"))
      ) {
        return repo;
      }
    }
    throw new RepoError(
      "nova_repo_not_found",
      "Nova source repository is not under an allowlisted bridge root",
      404,
    );
  }

  /** Bounded, literal multi-keyword search over Nova's readable source files. */
  searchNovaCode(query: string): CodeSearchResult {
    const normalized = query.trim();
    if (!normalized) {
      throw new RepoError("invalid_query", "query_required", 400);
    }
    if (normalized.length > 300) {
      throw new RepoError("invalid_query", "query_too_long", 400);
    }
    const repo = this.resolveNovaRepo();
    const terms = this.codeSearchTerms(normalized);
    if (terms.length === 0) {
      throw new RepoError("invalid_query", "no_searchable_terms", 400);
    }

    const matches: Array<CodeSearchMatch & { score: number }> = [];
    let visited = 0;
    let entriesVisited = 0;
    let scanTruncated = false;
    const walk = (directory: string, relativeDirectory: string): void => {
      if (scanTruncated) return;
      for (const name of readdirSync(directory).sort((a, b) => a.localeCompare(b))) {
        entriesVisited += 1;
        if (
          entriesVisited >= MAX_CODE_SEARCH_ENTRIES ||
          visited >= MAX_CODE_SEARCH_FILES ||
          matches.length >= MAX_CODE_SEARCH_MATCHES
        ) {
          scanTruncated = true;
          return;
        }
        if (name.startsWith(".") || this.isSkippableDir(name)) continue;
        const absolute = join(directory, name);
        const relative = relativeDirectory ? `${relativeDirectory}/${name}` : name;
        let stat;
        try {
          stat = lstatSync(absolute);
        } catch {
          continue;
        }
        if (stat.isSymbolicLink()) continue;
        if (stat.isDirectory()) {
          walk(absolute, relative);
          continue;
        }
        if (!stat.isFile() || !this.isReadableCodePath(relative, stat.size)) continue;
        visited += 1;
        let text: string;
        try {
          text = readFileSync(absolute, "utf8");
        } catch {
          continue;
        }
        if (text.includes("\u0000")) continue;
        const lines = text.split(/\r?\n/);
        let matchesInFile = 0;
        for (let index = 0; index < lines.length; index += 1) {
          const lowered = lines[index]!.toLowerCase();
          const matchedTerms = terms.filter((term) => lowered.includes(term));
          if (matchedTerms.length === 0) continue;
          const pathBoost = terms.filter((term) => relative.toLowerCase().includes(term)).length;
          matches.push({
            path: relative.replace(/\\/g, "/"),
            line: index + 1,
            snippet: lines[index]!.trim().slice(0, 360),
            matchedTerms,
            score: matchedTerms.length * 10 + pathBoost * 3,
          });
          matchesInFile += 1;
          if (matchesInFile >= 3 || matches.length >= MAX_CODE_SEARCH_MATCHES) break;
        }
      }
    };
    walk(repo.path, "");
    matches.sort(
      (a, b) =>
        b.score - a.score ||
        a.path.localeCompare(b.path) ||
        a.line - b.line,
    );
    const limited = matches.slice(0, MAX_CODE_SEARCH_RESULTS);
    return {
      repoId: repo.id,
      repoName: repo.name,
      query: normalized,
      matches: limited.map(({ score: _score, ...match }) => match),
      truncated: scanTruncated || matches.length > limited.length,
    };
  }

  /** Read an exact, bounded line range from a non-sensitive Nova source file. */
  readNovaCode(
    requestedPath: string,
    startLine = 1,
    endLine = startLine + 119,
  ): CodeReadResult {
    const repo = this.resolveNovaRepo();
    const resolved = this.resolveRepoPath(repo.id, requestedPath);
    if (resolved.kind !== "file") {
      throw new RepoError("invalid_path", "path_is_not_file", 400);
    }
    const size = statSync(resolved.absolutePath).size;
    if (!this.isReadableCodePath(resolved.relativePath, size)) {
      throw new RepoError("forbidden_file", "file_not_readable_as_source", 403);
    }
    const text = readFileSync(resolved.absolutePath, "utf8");
    if (text.includes("\u0000")) {
      throw new RepoError("forbidden_file", "binary_file_rejected", 403);
    }
    const lines = text.split(/\r?\n/);
    if (!Number.isFinite(startLine) || !Number.isFinite(endLine)) {
      throw new RepoError("invalid_lines", "line_numbers_must_be_finite", 400);
    }
    const start = Math.min(lines.length, Math.max(1, Math.floor(startLine)));
    const requestedEnd = Math.max(start, Math.floor(endLine));
    const end = Math.min(lines.length, requestedEnd, start + MAX_CODE_READ_LINES - 1);
    return {
      repoId: repo.id,
      repoName: repo.name,
      path: resolved.relativePath.replace(/\\/g, "/"),
      startLine: start,
      endLine: end,
      totalLines: lines.length,
      content: lines.slice(start - 1, end).join("\n"),
      truncated: requestedEnd > end,
    };
  }

  private codeSearchTerms(query: string): string[] {
    const stop = new Set([
      "about", "does", "from", "have", "into", "nova", "that", "the", "this",
      "what", "when", "where", "which", "with", "would", "could", "should",
    ]);
    return Array.from(
      new Set(
        query
          .toLowerCase()
          .replace(/[^a-z0-9_./-]+/g, " ")
          .split(/\s+/)
          .map((term) => term.trim())
          .filter((term) => term.length >= 2 && !stop.has(term)),
      ),
    ).slice(0, 10);
  }

  private isReadableCodePath(relativePath: string, size: number): boolean {
    if (size > MAX_CODE_FILE_BYTES) return false;
    const normalized = relativePath.replace(/\\/g, "/").toLowerCase();
    const inGroundingScope =
      normalized.startsWith("nova/sources/") ||
      normalized.startsWith("nova/app/") ||
      normalized.startsWith("nova/tests/") ||
      normalized.startsWith("nova-bridge/src/") ||
      normalized.startsWith("docs/") ||
      normalized === "nova/package.swift" ||
      normalized === "nova/project.yml" ||
      normalized === "nova-bridge/package.json";
    if (!inGroundingScope) return false;
    const parts = normalized.split("/");
    const name = parts.at(-1) ?? "";
    if (
      parts.some((part) => part.startsWith(".")) ||
      parts.some((part) => this.isSkippableDir(part)) ||
      name === ".env" ||
      name.includes("secret") ||
      name.includes("credential") ||
      name.endsWith(".ipa") ||
      name.endsWith(".xcarchive")
    ) {
      return false;
    }
    return [
      ".swift", ".ts", ".tsx", ".js", ".jsx", ".json", ".md", ".yml", ".yaml",
      ".toml", ".html", ".css",
    ].some((extension) => name.endsWith(extension));
  }

  /** Snapshot every currently-dirty path before an agent run. */
  async createBaseline(repoId: string): Promise<{ baselineId: string; fileCount: number }> {
    return this.withLock(repoId, async () => {
      const repo = this.resolveRepo(repoId);
      const status = await this.statusUnlocked(repo.path, repo.id, repo.name);
      const created = this.baselines.create(
        repo.id,
        repo.path,
        status.changedFiles.map((f) => f.path),
      );
      this.activeBaseline.set(repo.id, created.baselineId);
      return created;
    });
  }

  async agentReview(repoId: string, baselineId?: string | null): Promise<AgentReview> {
    return this.withLock(repoId, async () => {
      const repo = this.resolveRepo(repoId);
      const id = (baselineId ?? this.activeBaseline.get(repo.id) ?? "").trim();
      if (!id) throw new RepoError("not_found", "no_active_baseline", 404);
      const status = await this.statusUnlocked(repo.path, repo.id, repo.name);
      const review = this.baselines.review(
        repo.id,
        id,
        repo.path,
        status.changedFiles.map((f) => f.path),
      );
      this.activeBaseline.set(repo.id, id);
      return review;
    });
  }

  async keepReviewPaths(
    repoId: string,
    baselineId: string,
    paths: string[],
  ): Promise<AgentReview> {
    return this.withLock(repoId, async () => {
      const repo = this.resolveRepo(repoId);
      this.baselines.keep(repo.id, baselineId, paths);
      this.activeBaseline.set(repo.id, baselineId);
      const status = await this.statusUnlocked(repo.path, repo.id, repo.name);
      return this.baselines.review(
        repo.id,
        baselineId,
        repo.path,
        status.changedFiles.map((f) => f.path),
      );
    });
  }

  async restoreReviewPaths(
    repoId: string,
    baselineId: string,
    paths: string[],
    contentTokens?: Record<string, string>,
  ): Promise<AgentReview> {
    return this.withLock(repoId, async () => {
      const repo = this.resolveRepo(repoId);
      this.baselines.restore(repo.id, baselineId, repo.path, paths, contentTokens);
      this.activeBaseline.set(repo.id, baselineId);
      const status = await this.statusUnlocked(repo.path, repo.id, repo.name);
      return this.baselines.review(
        repo.id,
        baselineId,
        repo.path,
        status.changedFiles.map((f) => f.path),
      );
    });
  }

  activeBaselineId(repoId: string): string | null {
    return this.activeBaseline.get(repoId) ?? null;
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

      // Prefer agent-only remaining deltas from the active baseline when the
      // client omits paths. Pre-existing dirty files (unchanged vs baseline)
      // stay out of the PR. Fall back to the full dirty set when no baseline.
      let paths = req.paths?.length ? [...req.paths] : [];
      if (!paths.length) {
        const baselineId = this.activeBaseline.get(repo.id);
        if (baselineId) {
          try {
            const review = this.baselines.review(
              repo.id,
              baselineId,
              repo.path,
              current.changedFiles.map((f) => f.path),
            );
            paths = review.files.map((f) => f.path);
          } catch {
            paths = [];
          }
        }
        if (!paths.length) {
          paths = current.changedFiles.map((f) => f.path);
        }
      }
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

  /**
   * Commit every dirty path on the current branch, push to origin, then start
   * the GitHub Actions IPA job in the background. Returns immediately with a
   * `jobId` so the phone can poll instead of holding one HTTP socket for 10–25 min
   * (iOS/Wi‑Fi routinely drops that long request as "Lost connection mid-run").
   */
  async commitAndBuildIpa(req: CommitAndBuildRequest): Promise<CommitAndBuildResult> {
    const nova = this.resolveNovaRepo();
    this.requireGh(); // fail fast — run-ipa-ci.ps1 needs authenticated gh
    this.pruneIpaJobs();

    const pushed = await this.withLock(nova.id, async () => {
      const git = this.requireGit();
      const repo = nova;

      const current = await this.statusUnlocked(repo.path, repo.id, repo.name);
      const token = (req.statusToken ?? "").trim();
      if (token && token !== current.statusToken) {
        throw new RepoError("stale_status", "status_token_mismatch", 409);
      }

      const branch = current.branch;
      if (!branch || branch === "HEAD") {
        throw new RepoError("invalid_branch", "detached_head", 400);
      }

      let committed = false;
      if (!current.clean) {
        const message =
          (req.commitMessage ?? "").trim() ||
          `Nova: commit and build IPA (${new Date().toISOString().slice(0, 16)})`;
        if (message.startsWith("-")) {
          throw new RepoError("invalid_commit", "leading_option_rejected");
        }

        const add = await runProcess(git, ["add", "-A", "--"], { cwd: repo.path });
        if (add.code !== 0) {
          throw new RepoError(
            "stage_failed",
            add.stderr.trim().slice(0, 400) || "git_add_failed",
            502,
          );
        }

        const commit = await runProcess(
          git,
          ["commit", "-m", message, "--no-verify"],
          {
            cwd: repo.path,
            env: {
              GIT_AUTHOR_NAME: process.env.GIT_AUTHOR_NAME ?? "Nova Bridge",
              GIT_AUTHOR_EMAIL:
                process.env.GIT_AUTHOR_EMAIL ?? "nova-bridge@local",
              GIT_COMMITTER_NAME:
                process.env.GIT_COMMITTER_NAME ?? "Nova Bridge",
              GIT_COMMITTER_EMAIL:
                process.env.GIT_COMMITTER_EMAIL ?? "nova-bridge@local",
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
        committed = true;
      }

      const shaRes = await runProcess(git, ["rev-parse", "HEAD"], {
        cwd: repo.path,
      });
      const commitSha = shaRes.stdout.trim();
      if (!commitSha) {
        throw new RepoError("commit_failed", "missing_head_sha", 502);
      }

      let didPush = false;
      const needsPush = committed || current.ahead > 0 || !current.upstream;
      if (needsPush) {
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
        didPush = true;
      }

      return {
        repoId: repo.id,
        repoPath: repo.path,
        branch,
        commitSha,
        committed,
        pushed: didPush,
      };
    });

    const ipaRelativePath = "Nova/App/NovaApp.ipa";
    const ipaPath = join(pushed.repoPath, "Nova", "App", "NovaApp.ipa");
    const scriptPath = join(pushed.repoPath, "Nova", "scripts", "run-ipa-ci.ps1");
    if (!existsSync(scriptPath)) {
      throw new RepoError(
        "ipa_script_missing",
        "Nova/scripts/run-ipa-ci.ps1 not found",
        500,
      );
    }

    const jobId = `ipa-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    const initial: IpaBuildJob = {
      jobId,
      repoId: pushed.repoId,
      branch: pushed.branch,
      commitSha: pushed.commitSha,
      committed: pushed.committed,
      pushed: pushed.pushed,
      ipaPath,
      ipaRelativePath,
      workflowRunId: null,
      buildStatus: "building",
      detail: `Pushed ${pushed.commitSha.slice(0, 7)} on ${pushed.branch}. Waiting on GitHub Actions IPA (often 10–25 min)…`,
      updatedAt: Date.now(),
    };
    this.ipaJobs.set(jobId, initial);

    // Fire-and-forget: do not hold the HTTP request open for the macOS CI wait.
    void this.runIpaCiJob(jobId, {
      repoPath: pushed.repoPath,
      branch: pushed.branch,
      commitSha: pushed.commitSha,
      scriptPath,
      ipaPath,
      ipaRelativePath,
    });

    if (req.asyncPoll === true) {
      return { ...initial };
    }

    // Legacy phone clients hold the POST open until CI finishes.
    return this.waitForIpaJob(jobId);
  }

  /** Poll status for a background Commit-and-Build IPA job. */
  getCommitAndBuildJob(jobId: string): CommitAndBuildResult {
    this.pruneIpaJobs();
    const id = (jobId ?? "").trim();
    const job = this.ipaJobs.get(id);
    if (!job) {
      throw new RepoError("ipa_job_not_found", "unknown_or_expired_job", 404);
    }
    const { errorCode: _errorCode, updatedAt: _updatedAt, ...publicResult } = job;
    return publicResult;
  }

  private async waitForIpaJob(jobId: string): Promise<CommitAndBuildResult> {
    const deadline = Date.now() + IPA_BUILD_TIMEOUT_MS + 60_000;
    while (Date.now() < deadline) {
      const job = this.getCommitAndBuildJob(jobId);
      if (job.buildStatus === "completed") return job;
      if (job.buildStatus === "failed") {
        throw new RepoError("ipa_build_failed", job.detail, 502);
      }
      await new Promise((r) => setTimeout(r, 4000));
    }
    throw new RepoError("ipa_build_timeout", "timed_out_waiting_for_ipa_job", 504);
  }

  private pruneIpaJobs(): void {
    const cutoff = Date.now() - IPA_JOB_TTL_MS;
    for (const [id, job] of this.ipaJobs) {
      if (job.updatedAt < cutoff) this.ipaJobs.delete(id);
    }
  }

  private async runIpaCiJob(
    jobId: string,
    opts: {
      repoPath: string;
      branch: string;
      commitSha: string;
      scriptPath: string;
      ipaPath: string;
      ipaRelativePath: string;
    },
  ): Promise<void> {
    const ps = process.platform === "win32" ? "powershell.exe" : "pwsh";
    try {
      const build = await runProcess(
        ps,
        [
          "-NoProfile",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          opts.scriptPath,
          "-Ref",
          opts.branch,
        ],
        {
          cwd: join(opts.repoPath, "Nova"),
          timeoutMs: IPA_BUILD_TIMEOUT_MS,
          maxStdout: 1_000_000,
        },
      );
      const existing = this.ipaJobs.get(jobId);
      if (!existing) return;

      if (build.code !== 0 || !existsSync(opts.ipaPath)) {
        const combined = `${build.stderr}\n${build.stdout}`.trim();
        const detail = summarizeIpaBuildFailure(combined);
        this.ipaJobs.set(jobId, {
          ...existing,
          buildStatus: "failed",
          detail,
          errorCode: "ipa_build_failed",
          updatedAt: Date.now(),
        });
        return;
      }

      const runMatch = (build.stdout + "\n" + build.stderr).match(
        /Run\s+(\d+)\s+started/i,
      );
      this.ipaJobs.set(jobId, {
        ...existing,
        workflowRunId: runMatch?.[1] ?? null,
        buildStatus: "completed",
        detail: `IPA ready at Nova/App/NovaApp.ipa (${opts.commitSha.slice(0, 7)} on ${opts.branch})`,
        updatedAt: Date.now(),
      });
    } catch (err) {
      const existing = this.ipaJobs.get(jobId);
      if (!existing) return;
      const raw =
        err instanceof Error ? err.message.slice(0, 400) : "ipa_build_failed";
      const detail = /process_timeout_\d+ms/i.test(raw)
        ? `GitHub Actions IPA job did not finish within ${Math.round(IPA_BUILD_TIMEOUT_MS / 60_000)} minutes (bridge stopped waiting). Check Actions on GitHub — the workflow may still be running or queued. If it finished later, run Commit and Build again or download the IPA with Nova/scripts/run-ipa-ci.ps1.`
        : raw;
      this.ipaJobs.set(jobId, {
        ...existing,
        buildStatus: "failed",
        detail,
        errorCode: "ipa_build_failed",
        updatedAt: Date.now(),
      });
    }
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

/** Prefer Swift/xcodebuild errors over Node/action deprecation noise in IPA logs. */
export function summarizeIpaBuildFailure(combined: string): string {
  const timeout = combined.match(/process_timeout_(\d+)ms/i);
  if (timeout) {
    const minutes = Math.max(1, Math.round(Number(timeout[1]) / 60_000));
    return `GitHub Actions IPA wait timed out after ${minutes} minutes. Check the Actions tab — CI may still be running; retry Commit and Build or run Nova/scripts/run-ipa-ci.ps1 when it finishes.`;
  }
  const lines = combined.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const noise =
    /Node\.js 20|actions\/checkout|actions\/setup-node|github\.blog\/changelog|DEPRECATED/i;
  const compile = lines.filter(
    (l) => /\berror:/i.test(l) && !noise.test(l),
  );
  if (compile.length > 0) {
    return compile
      .slice(-6)
      .map((l) => l.replace(/^.*?error:\s*/i, "error: "))
      .join(" | ")
      .slice(-500);
  }
  const actionable = lines.filter(
    (l) =>
      /did not succeed|Failed:|ipa_build|Run \d+/i.test(l) && !noise.test(l),
  );
  if (actionable.length > 0) {
    return actionable.slice(-4).join(" | ").slice(-500);
  }
  return (combined.slice(-500) || "IPA build failed").trim();
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
