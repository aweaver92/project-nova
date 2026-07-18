/**
 * Pre-run repository baselines so Coding can review/revert only agent-made
 * changes without destroying pre-existing dirty work.
 *
 * Snapshots live outside allowlisted repo roots:
 *   %LOCALAPPDATA%/nova-bridge/baselines/<repoId>/<baselineId>/
 */
import { createHash, randomBytes } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { RepoError } from "./repo-service.js";

const BASELINE_TTL_MS = 24 * 60 * 60 * 1000;
const MAX_FILE_BYTES = 2_000_000;
const MAX_DIFF_CHARS = 40_000;
const MAX_BASELINE_FILES = 400;

export type BaselineFileRecord = {
  path: string;
  existed: boolean;
  /** SHA-256 of baseline bytes, or null when the file did not exist. */
  hash: string | null;
  /** Opaque token for concurrent-edit detection at restore time. */
  contentToken: string;
  /** Relative path under the baseline dir for the copied bytes (if any). */
  blob?: string;
  size: number;
  binary: boolean;
};

export type BaselineManifest = {
  baselineId: string;
  repoId: string;
  createdAt: number;
  files: BaselineFileRecord[];
  /** Paths the user chose to Keep (removed from pending review). */
  kept: string[];
};

export type AgentReviewFile = {
  path: string;
  /** "added" | "modified" | "deleted" | "binary" */
  change: "added" | "modified" | "deleted" | "binary";
  diff: string;
  truncated: boolean;
  binary: boolean;
  contentToken: string;
  kept: boolean;
};

export type AgentReview = {
  baselineId: string;
  repoId: string;
  files: AgentReviewFile[];
  pendingCount: number;
  keptCount: number;
};

function defaultStateRoot(): string {
  if (process.env.NOVA_BRIDGE_STATE_DIR?.trim()) {
    return process.env.NOVA_BRIDGE_STATE_DIR.trim();
  }
  if (process.env.LOCALAPPDATA) {
    return join(process.env.LOCALAPPDATA, "nova-bridge");
  }
  return join(tmpdir(), "nova-bridge");
}

function isProbablyBinary(buf: Buffer): boolean {
  const sample = buf.subarray(0, Math.min(buf.length, 8_000));
  if (sample.includes(0)) return true;
  let weird = 0;
  for (const b of sample) {
    if (b < 7 || (b > 14 && b < 32)) weird += 1;
  }
  return weird / Math.max(sample.length, 1) > 0.3;
}

function hashBytes(buf: Buffer): string {
  return createHash("sha256").update(buf).digest("hex");
}

function contentTokenFor(path: string, hash: string | null, size: number): string {
  return createHash("sha256")
    .update(`${path}\0${hash ?? "missing"}\0${size}`)
    .digest("hex")
    .slice(0, 24);
}

function assertSafeRel(rel: string): void {
  if (!rel || rel.startsWith("-") || rel.includes("\0")) {
    throw new RepoError("invalid_path", "unsafe_path");
  }
  if (rel.includes("..") || rel.startsWith("/") || /^[a-zA-Z]:/.test(rel)) {
    throw new RepoError("invalid_path", "path_escape");
  }
  if (rel.startsWith("\\\\") || rel.startsWith("//")) {
    throw new RepoError("invalid_path", "unc_rejected");
  }
  if (rel.split("/").some((p) => !p || p.startsWith("."))) {
    throw new RepoError("invalid_path", "hidden_path_rejected", 403);
  }
}

function unifiedDiff(path: string, before: string | null, after: string | null): string {
  const a = (before ?? "").replace(/\r\n/g, "\n").split("\n");
  const b = (after ?? "").replace(/\r\n/g, "\n").split("\n");
  // Drop trailing empty line from split so empty files look clean.
  if (a.length && a[a.length - 1] === "") a.pop();
  if (b.length && b[b.length - 1] === "") b.pop();

  const lines: string[] = [
    `--- a/${path}`,
    `+++ b/${path}`,
    `@@ -${before == null ? 0 : 1},${a.length} +${after == null ? 0 : 1},${b.length} @@`,
  ];
  for (const line of a) lines.push(`-${line}`);
  for (const line of b) lines.push(`+${line}`);
  let text = lines.join("\n");
  if (text.length > MAX_DIFF_CHARS) {
    text = text.slice(0, MAX_DIFF_CHARS) + "\n# … truncated …\n";
  }
  return text;
}

export class BaselineService {
  readonly root: string;

  constructor(stateRoot?: string) {
    this.root = join(stateRoot ?? defaultStateRoot(), "baselines");
    mkdirSync(this.root, { recursive: true });
  }

  private repoDir(repoId: string): string {
    return join(this.root, repoId);
  }

  private baselineDir(repoId: string, baselineId: string): string {
    return join(this.repoDir(repoId), baselineId);
  }

  private manifestPath(repoId: string, baselineId: string): string {
    return join(this.baselineDir(repoId, baselineId), "manifest.json");
  }

  expireOld(): void {
    const cutoff = Date.now() - BASELINE_TTL_MS;
    if (!existsSync(this.root)) return;
    for (const repoId of readdirSync(this.root)) {
      const repoPath = join(this.root, repoId);
      try {
        for (const baselineId of readdirSync(repoPath)) {
          const manifestFile = join(repoPath, baselineId, "manifest.json");
          if (!existsSync(manifestFile)) {
            rmSync(join(repoPath, baselineId), { recursive: true, force: true });
            continue;
          }
          try {
            const manifest = JSON.parse(
              readFileSync(manifestFile, "utf8"),
            ) as BaselineManifest;
            if (manifest.createdAt < cutoff) {
              rmSync(join(repoPath, baselineId), { recursive: true, force: true });
            }
          } catch {
            rmSync(join(repoPath, baselineId), { recursive: true, force: true });
          }
        }
      } catch {
        /* ignore */
      }
    }
  }

  create(
    repoId: string,
    repoPath: string,
    changedPaths: string[],
  ): { baselineId: string; fileCount: number } {
    this.expireOld();
    const baselineId = randomBytes(8).toString("hex");
    const dir = this.baselineDir(repoId, baselineId);
    const blobs = join(dir, "blobs");
    mkdirSync(blobs, { recursive: true });

    const unique = [...new Set(changedPaths.map((p) => p.replace(/\\/g, "/")))];
    if (unique.length > MAX_BASELINE_FILES) {
      throw new RepoError("baseline_too_large", `maximum_${MAX_BASELINE_FILES}_files`, 413);
    }

    const files: BaselineFileRecord[] = [];
    for (const rel of unique) {
      assertSafeRel(rel);
      const abs = join(repoPath, ...rel.split("/"));
      if (!existsSync(abs)) {
        files.push({
          path: rel,
          existed: false,
          hash: null,
          contentToken: contentTokenFor(rel, null, 0),
          size: 0,
          binary: false,
        });
        continue;
      }
      const st = statSync(abs);
      if (!st.isFile()) continue;
      if (st.size > MAX_FILE_BYTES) {
        throw new RepoError("file_too_large", `${rel}_exceeds_2mb`, 413);
      }
      const buf = readFileSync(abs);
      const hash = hashBytes(buf);
      const binary = isProbablyBinary(buf);
      const blobName = `${files.length.toString().padStart(4, "0")}.bin`;
      copyFileSync(abs, join(blobs, blobName));
      files.push({
        path: rel,
        existed: true,
        hash,
        contentToken: contentTokenFor(rel, hash, st.size),
        blob: `blobs/${blobName}`,
        size: st.size,
        binary,
      });
    }

    const manifest: BaselineManifest = {
      baselineId,
      repoId,
      createdAt: Date.now(),
      files,
      kept: [],
    };
    writeFileSync(this.manifestPath(repoId, baselineId), JSON.stringify(manifest), "utf8");
    return { baselineId, fileCount: files.length };
  }

  load(repoId: string, baselineId: string): BaselineManifest {
    if (!/^[a-f0-9]{16}$/.test(repoId) || !/^[a-f0-9]{16}$/.test(baselineId)) {
      throw new RepoError("not_found", "unknown_baseline", 404);
    }
    const file = this.manifestPath(repoId, baselineId);
    if (!existsSync(file)) throw new RepoError("not_found", "unknown_baseline", 404);
    const manifest = JSON.parse(readFileSync(file, "utf8")) as BaselineManifest;
    if (Date.now() - manifest.createdAt > BASELINE_TTL_MS) {
      rmSync(this.baselineDir(repoId, baselineId), { recursive: true, force: true });
      throw new RepoError("not_found", "baseline_expired", 404);
    }
    return manifest;
  }

  private save(manifest: BaselineManifest): void {
    writeFileSync(
      this.manifestPath(manifest.repoId, manifest.baselineId),
      JSON.stringify(manifest),
      "utf8",
    );
  }

  private readBlob(manifest: BaselineManifest, record: BaselineFileRecord): Buffer | null {
    if (!record.existed || !record.blob) return null;
    const abs = join(this.baselineDir(manifest.repoId, manifest.baselineId), record.blob);
    if (!existsSync(abs)) return null;
    return readFileSync(abs);
  }

  private currentSnapshot(
    repoPath: string,
    rel: string,
  ): { exists: boolean; hash: string | null; size: number; buf: Buffer | null; binary: boolean } {
    const abs = join(repoPath, ...rel.split("/"));
    if (!existsSync(abs)) {
      return { exists: false, hash: null, size: 0, buf: null, binary: false };
    }
    const st = statSync(abs);
    if (!st.isFile()) {
      return { exists: false, hash: null, size: 0, buf: null, binary: false };
    }
    const buf = readFileSync(abs);
    return {
      exists: true,
      hash: hashBytes(buf),
      size: st.size,
      buf,
      binary: isProbablyBinary(buf),
    };
  }

  /**
   * Compare the live tree to the baseline. Also discovers files that are dirty
   * now but were clean (absent from baseline inventory) — those are treated as
   * agent-added only when they appear in `currentChangedPaths` and were not in
   * the baseline set. Pre-existing dirty paths are in the baseline inventory; if
   * their content is unchanged vs baseline they are excluded from the review.
   */
  review(
    repoId: string,
    baselineId: string,
    repoPath: string,
    currentChangedPaths: string[],
  ): AgentReview {
    const manifest = this.load(repoId, baselineId);
    const keptSet = new Set(manifest.kept);
    const baselineByPath = new Map(manifest.files.map((f) => [f.path, f]));
    const candidates = new Set<string>([
      ...manifest.files.map((f) => f.path),
      ...currentChangedPaths.map((p) => p.replace(/\\/g, "/")),
    ]);

    const files: AgentReviewFile[] = [];
    for (const rel of [...candidates].sort()) {
      assertSafeRel(rel);
      const baseline = baselineByPath.get(rel);
      const current = this.currentSnapshot(repoPath, rel);

      // Path was clean before the run and is still clean → ignore.
      if (!baseline && !current.exists) continue;
      // Path was clean before the run and is not in current porcelain → ignore.
      if (!baseline && !currentChangedPaths.map((p) => p.replace(/\\/g, "/")).includes(rel)) {
        continue;
      }

      const baselineHash = baseline?.hash ?? null;
      const currentHash = current.hash;
      if (baselineHash === currentHash) {
        // Unchanged vs pre-run state (including still-dirty pre-existing files).
        continue;
      }

      let change: AgentReviewFile["change"];
      if (!baseline?.existed && current.exists) change = "added";
      else if (baseline?.existed && !current.exists) change = "deleted";
      else if (baseline?.binary || current.binary) change = "binary";
      else change = "modified";

      const beforeBuf = baseline ? this.readBlob(manifest, baseline) : null;
      const beforeText =
        beforeBuf && !(baseline?.binary) ? beforeBuf.toString("utf8") : null;
      const afterText =
        current.buf && !current.binary ? current.buf.toString("utf8") : null;
      const treatAsBinary = change === "binary" || current.binary || !!baseline?.binary;

      let diff = "";
      let truncated = false;
      if (treatAsBinary) {
        diff = `# binary file changed: ${rel}\n`;
      } else {
        diff = unifiedDiff(
          rel,
          baseline?.existed ? beforeText : null,
          current.exists ? afterText : null,
        );
        truncated = diff.includes("# … truncated …");
      }

      const token = contentTokenFor(rel, currentHash, current.size);
      files.push({
        path: rel,
        change,
        diff,
        truncated,
        binary: treatAsBinary,
        contentToken: token,
        kept: keptSet.has(rel),
      });
    }

    const pending = files.filter((f) => !f.kept);
    return {
      baselineId,
      repoId,
      files,
      pendingCount: pending.length,
      keptCount: files.length - pending.length,
    };
  }

  keep(repoId: string, baselineId: string, paths: string[]): BaselineManifest {
    const manifest = this.load(repoId, baselineId);
    for (const p of paths) assertSafeRel(p);
    const set = new Set(manifest.kept);
    for (const p of paths) set.add(p.replace(/\\/g, "/"));
    manifest.kept = [...set];
    this.save(manifest);
    return manifest;
  }

  restore(
    repoId: string,
    baselineId: string,
    repoPath: string,
    paths: string[],
    expectedTokens?: Record<string, string>,
  ): { restored: string[] } {
    const manifest = this.load(repoId, baselineId);
    const byPath = new Map(manifest.files.map((f) => [f.path, f]));
    const restored: string[] = [];

    for (const raw of paths) {
      const rel = raw.replace(/\\/g, "/");
      assertSafeRel(rel);
      const baseline = byPath.get(rel);
      const current = this.currentSnapshot(repoPath, rel);
      const currentToken = contentTokenFor(rel, current.hash, current.size);

      if (expectedTokens?.[rel] && expectedTokens[rel] !== currentToken) {
        throw new RepoError("stale_review", `${rel}_changed_since_review`, 409);
      }

      const abs = join(repoPath, ...rel.split("/"));
      if (!baseline || !baseline.existed) {
        // File was created by the agent — delete it.
        if (current.exists) {
          unlinkSync(abs);
        }
        restored.push(rel);
        continue;
      }

      const blob = this.readBlob(manifest, baseline);
      if (!blob) throw new RepoError("baseline_corrupt", `${rel}_missing_blob`, 500);
      mkdirSync(dirname(abs), { recursive: true });
      writeFileSync(abs, blob);
      restored.push(rel);
    }

    // Restored paths leave the pending review (equivalent to keep after undo).
    const set = new Set(manifest.kept);
    for (const p of restored) set.add(p);
    manifest.kept = [...set];
    this.save(manifest);
    return { restored };
  }

  pendingPaths(repoId: string, baselineId: string, repoPath: string, changed: string[]): string[] {
    const review = this.review(repoId, baselineId, repoPath, changed);
    return review.files.filter((f) => !f.kept).map((f) => f.path);
  }

  discard(repoId: string, baselineId: string): void {
    rmSync(this.baselineDir(repoId, baselineId), { recursive: true, force: true });
  }
}
