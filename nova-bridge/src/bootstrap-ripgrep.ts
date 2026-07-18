import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * `@cursor/sdk` needs a ripgrep binary for local agents (gitignore scanning +
 * codebase search). On Windows ARM there is no `@cursor/sdk-win32-arm64`
 * package yet, so optionalDeps never install one. Seed CURSOR_RIPGREP_PATH
 * from Cursor's own bundled `rg.exe` (or a user override) before Agent.create.
 */
export function bootstrapCursorRipgrep(): string | null {
  const existing = process.env.CURSOR_RIPGREP_PATH?.trim();
  if (existing && existsSync(existing)) return existing;

  const localAppData = process.env.LOCALAPPDATA ?? "";
  const candidates = [
    // Explicit override already handled above.
    // Cursor IDE (user install) — preferred on Windows ARM.
    join(localAppData, "Programs", "cursor", "resources", "app", "node_modules", "@vscode", "ripgrep", "bin", "rg.exe"),
    join(localAppData, "Programs", "cursor", "_", "resources", "app", "node_modules", "@vscode", "ripgrep", "bin", "rg.exe"),
    // Cursor SDK platform package (x64 machines / emulation).
    resolve(
      dirname(fileURLToPath(import.meta.url)),
      "..",
      "node_modules",
      "@cursor",
      "sdk-win32-x64",
      "rg.exe",
    ),
    resolve(
      dirname(fileURLToPath(import.meta.url)),
      "..",
      "node_modules",
      "@cursor",
      "sdk-win32-x64",
      "bin",
      "rg.exe",
    ),
  ];

  for (const candidate of candidates) {
    if (candidate && existsSync(candidate)) {
      process.env.CURSOR_RIPGREP_PATH = candidate;
      return candidate;
    }
  }
  return null;
}
