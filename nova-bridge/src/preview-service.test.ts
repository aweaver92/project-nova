/**
 * Checks for preview helpers plus a real static-server round trip.
 * Run: npx tsx src/preview-service.test.ts
 */
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import {
  buildPreviewUrls,
  detectPreviewKind,
  devServerArgs,
  isRemoteBridgeHost,
  PreviewService,
  previewUrl,
  safeStaticPath,
} from "./preview-service.js";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

// --- detectPreviewKind ------------------------------------------------------
const tmp = mkdtempSync(join(tmpdir(), "nova-preview-"));
try {
  writeFileSync(join(tmp, "index.html"), "<h1>hi</h1>");
  assert(detectPreviewKind(tmp) === "static", "no package.json → static");

  writeFileSync(
    join(tmp, "package.json"),
    JSON.stringify({ scripts: { build: "x" } }),
  );
  assert(detectPreviewKind(tmp) === "static", "no dev script → static");

  writeFileSync(
    join(tmp, "package.json"),
    JSON.stringify({ scripts: { dev: "vite" }, devDependencies: { vite: "^5" } }),
  );
  assert(detectPreviewKind(tmp) === "vite", "vite dep → vite");

  writeFileSync(
    join(tmp, "package.json"),
    JSON.stringify({ scripts: { dev: "next dev" }, dependencies: { next: "14" } }),
  );
  assert(detectPreviewKind(tmp) === "nextjs", "next dep → nextjs");

  writeFileSync(
    join(tmp, "package.json"),
    JSON.stringify({ scripts: { dev: "node server.js" } }),
  );
  assert(detectPreviewKind(tmp) === "dev", "generic dev script → dev");

  // --- devServerArgs --------------------------------------------------------
  assert(devServerArgs("vite", 8791).includes("--strictPort"), "vite strict port");
  assert(devServerArgs("nextjs", 8791).includes("-H"), "next host flag");
  assert(devServerArgs("dev", 8791).length === 2, "generic dev args");

  // --- safeStaticPath -------------------------------------------------------
  assert(safeStaticPath(tmp, "/index.html") === join(tmp, "index.html"), "plain path");
  assert(safeStaticPath(tmp, "/../secret") === null, "escape rejected");
  assert(safeStaticPath(tmp, "/.git/config") === null, "dotdir rejected");
  assert(safeStaticPath(tmp, "/.env") === null, "dotfile rejected");
  assert(safeStaticPath(tmp, `/..${sep}..${sep}x`) === null, "sep escape rejected");

  // --- previewUrl -----------------------------------------------------------
  assert(previewUrl("192.168.1.20:8787", 8790) === "http://192.168.1.20:8790/", "host from header");
  assert(previewUrl(undefined, 8790).startsWith("http://"), "fallback host");
  assert(isRemoteBridgeHost("192.168.1.20:8787") === false, "LAN host not remote");
  assert(isRemoteBridgeHost("pc.tailnet.ts.net") === true, "ts.net is remote");

  const lanBundle = buildPreviewUrls({
    requestHostHeader: "192.168.1.20:8787",
    bridgeOrigin: "http://192.168.1.20:8787",
    port: 8790,
    repoId: "abcd",
    tailscaleIp: null,
  });
  assert(lanBundle.access === "lan", "LAN access");
  assert(lanBundle.url === "http://192.168.1.20:8790/", "LAN url from host");

  const tsBundle = buildPreviewUrls({
    requestHostHeader: "pc.tailnet.ts.net",
    bridgeOrigin: "https://pc.tailnet.ts.net",
    port: 8790,
    repoId: "abcd",
    relativePath: "index.html",
    tailscaleIp: "100.64.1.2",
  });
  assert(tsBundle.access === "remote", "Tailscale access");
  assert(tsBundle.remoteVia === "tailscale", "uses Tailscale IP");
  assert(tsBundle.url === "http://100.64.1.2:8790/index.html", "Tailscale preview url");

  const proxyBundle = buildPreviewUrls({
    requestHostHeader: "pc.tailnet.ts.net",
    bridgeOrigin: "https://pc.tailnet.ts.net",
    port: 8790,
    repoId: "cafe0123",
    tailscaleIp: null,
  });
  assert(proxyBundle.remoteVia === "bridge-proxy", "proxy fallback");
  assert(
    proxyBundle.url === "https://pc.tailnet.ts.net/preview-proxy/cafe0123/",
    "bridge proxy url",
  );

  // --- static server round trip --------------------------------------------
  rmSync(join(tmp, "package.json")); // otherwise detect would pick "dev"
  writeFileSync(join(tmp, "index.html"), "<h1>nova-preview-ok</h1>");
  mkdirSync(join(tmp, "about"), { recursive: true });
  writeFileSync(join(tmp, "about", "index.html"), "<h1>about</h1>");

  const service = new PreviewService({ portBase: 18790, portCount: 3 });
  const info = await service.start(
    "cafe0123cafe0123",
    tmp,
    "index.html",
    "index.html",
    "index.html",
  );
  assert(info.kind === "static", "static round trip kind");
  assert(info.path === "index.html", "selected target path exposed");
  assert(info.urlPath === "index.html", "selected file URL path exposed");

  // Wait for listen callback.
  for (let i = 0; i < 20 && service.get("cafe0123cafe0123")?.state !== "ready"; i++) {
    await new Promise((r) => setTimeout(r, 50));
  }
  const ready = service.get("cafe0123cafe0123");
  assert(ready?.state === "ready", `static ready (got ${ready?.state})`);

  const root = await fetch(`http://127.0.0.1:${info.port}/`);
  assert(root.ok && (await root.text()).includes("nova-preview-ok"), "serves index.html");
  const nested = await fetch(`http://127.0.0.1:${info.port}/about`);
  assert(nested.ok && (await nested.text()).includes("about"), "serves nested index");
  const blocked = await fetch(`http://127.0.0.1:${info.port}/.git/config`);
  assert(blocked.status === 403, "blocks dotfiles");

  const stopped = await service.stop("cafe0123cafe0123");
  assert(stopped, "stop returns true");
  assert(service.list().length === 0, "list empty after stop");
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

console.log("preview-service.test.ts: ok");
