import { existsSync } from "node:fs";
import { delimiter, join } from "node:path";

/**
 * Locate git / gh binaries for the repository lifecycle APIs.
 * Prefer explicit env overrides, then PATH, then known Windows install paths.
 */

function pathCandidates(name: string): string[] {
  const out: string[] = [];
  const pathEnv = process.env.PATH ?? "";
  for (const dir of pathEnv.split(delimiter)) {
    if (!dir) continue;
    out.push(join(dir, name));
    if (process.platform === "win32" && !name.endsWith(".exe")) {
      out.push(join(dir, `${name}.exe`));
    }
  }
  return out;
}

function firstExisting(candidates: string[]): string | null {
  for (const c of candidates) {
    if (c && existsSync(c)) return c;
  }
  return null;
}

export function resolveGitBin(override?: string): string | null {
  const explicit = (override ?? process.env.GIT_BIN ?? "").trim();
  if (explicit) return existsSync(explicit) ? explicit : null;

  const known =
    process.platform === "win32"
      ? [
          "C:\\Program Files\\Git\\cmd\\git.exe",
          "C:\\Program Files\\Git\\bin\\git.exe",
          "C:\\Program Files (x86)\\Git\\cmd\\git.exe",
        ]
      : ["/usr/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git"];

  return firstExisting([...pathCandidates("git"), ...known]);
}

export function resolveGhBin(override?: string): string | null {
  const explicit = (override ?? process.env.GH_BIN ?? "").trim();
  if (explicit) return existsSync(explicit) ? explicit : null;

  const known =
    process.platform === "win32"
      ? [
          "C:\\Program Files\\GitHub CLI\\gh.exe",
          join(process.env.LOCALAPPDATA ?? "", "Programs", "GitHub CLI", "gh.exe"),
        ]
      : ["/usr/bin/gh", "/usr/local/bin/gh", "/opt/homebrew/bin/gh"];

  return firstExisting([...pathCandidates("gh"), ...known]);
}

export type ToolReadiness = {
  gitBin: string | null;
  ghBin: string | null;
  gitReady: boolean;
  ghReady: boolean;
};

export function toolReadiness(): ToolReadiness {
  const gitBin = resolveGitBin();
  const ghBin = resolveGhBin();
  return {
    gitBin,
    ghBin,
    gitReady: Boolean(gitBin),
    ghReady: Boolean(ghBin),
  };
}
