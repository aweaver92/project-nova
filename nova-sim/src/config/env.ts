import * as fs from "fs";
import * as path from "path";

/**
 * Minimal .env loader (zero deps). Existing process.env values win, so an
 * explicitly exported OPENAI_API_KEY still overrides the file.
 * Searches upward from cwd so it works regardless of where the CLI is invoked.
 */
export function loadDotEnv(startDir: string = process.cwd()): void {
  const envPath = findEnvFile(startDir);
  if (!envPath) return;

  const contents = fs.readFileSync(envPath, "utf8");
  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;

    const eq = line.indexOf("=");
    if (eq === -1) continue;

    const key = line.slice(0, eq).trim();
    if (!key || key in process.env) continue;

    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    process.env[key] = value;
  }
}

function findEnvFile(startDir: string): string | undefined {
  let dir = path.resolve(startDir);
  while (true) {
    const candidate = path.join(dir, ".env");
    if (fs.existsSync(candidate)) return candidate;
    const parent = path.dirname(dir);
    if (parent === dir) return undefined;
    dir = parent;
  }
}
