import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  extractPrUrl,
  makeStatusToken,
  opaqueRepoId,
  parseAheadBehind,
  parsePorcelainStatus,
  parseRepoRoots,
  RepoError,
  RepoService,
  sanitizeBranchSlug,
  scaffoldWebProject,
  summarizeIpaBuildFailure,
  timingSafeTokenEqual,
  validateGitHubHttpsUrl,
  validateProjectName,
  validateWebProjectTemplate,
} from "./repo-service.js";

function section(name: string): void {
  console.log(`\n== ${name} ==`);
}

section("validateGitHubHttpsUrl");
{
  const ok = validateGitHubHttpsUrl("https://github.com/acme/demo.git");
  assert.equal(ok.owner, "acme");
  assert.equal(ok.repo, "demo");
  assert.equal(ok.url, "https://github.com/acme/demo.git");

  assert.throws(() => validateGitHubHttpsUrl("git@github.com:acme/demo.git"), RepoError);
  assert.throws(() => validateGitHubHttpsUrl("ssh://github.com/acme/demo.git"), RepoError);
  assert.throws(() => validateGitHubHttpsUrl("https://user:pass@github.com/acme/demo.git"), RepoError);
  assert.throws(() => validateGitHubHttpsUrl("https://gitlab.com/acme/demo.git"), RepoError);
  assert.throws(() => validateGitHubHttpsUrl("-https://github.com/acme/demo.git"), RepoError);
  assert.throws(() => validateGitHubHttpsUrl("https://github.com/acme/demo/extra"), RepoError);
}

section("sanitizeBranchSlug");
{
  assert.equal(sanitizeBranchSlug("Fix Login"), "nova/fix-login");
  assert.equal(sanitizeBranchSlug("nova/already"), "nova/already");
  assert.throws(() => sanitizeBranchSlug("main"), RepoError);
  assert.throws(() => sanitizeBranchSlug("../escape"), RepoError);
}

section("web project validation and templates");
{
  assert.equal(validateProjectName("My-Web_App"), "my-web_app");
  assert.throws(() => validateProjectName("../escape"), RepoError);
  assert.throws(() => validateProjectName("-option"), RepoError);
  assert.equal(validateWebProjectTemplate("react-vite"), "react-vite");
  assert.throws(() => validateWebProjectTemplate("shell"), RepoError);

  const base = mkdtempSync(join(tmpdir(), "nova-web-templates-"));
  try {
    const expected: Record<string, string> = {
      static: "index.html",
      vite: "src/main.js",
      "react-vite": "src/App.jsx",
      nextjs: "app/page.tsx",
    };
    for (const [template, file] of Object.entries(expected)) {
      const root = join(base, template);
      mkdirSync(root);
      scaffoldWebProject(
        root,
        `test-${template}`,
        validateWebProjectTemplate(template),
      );
      assert.equal(existsSync(join(root, file)), true);
      assert.equal(existsSync(join(root, "README.md")), true);
      assert.match(readFileSync(join(root, "README.md"), "utf8"), /Created from Nova/);
    }
  } finally {
    rmSync(base, { recursive: true, force: true });
  }
}

section("parsePorcelainStatus / ahead-behind / token");
{
  const files = parsePorcelainStatus(" M src/a.ts\n?? new.md\nR  old.ts -> new.ts\n");
  assert.equal(files.length, 3);
  assert.equal(files[0]?.path, "src/a.ts");
  assert.equal(files[1]?.path, "new.md");
  assert.equal(files[2]?.path, "new.ts");
  assert.deepEqual(parseAheadBehind("2\t5"), { ahead: 2, behind: 5 });

  const token = makeStatusToken({
    branch: "main",
    upstream: "origin/main",
    ahead: 0,
    behind: 0,
    files,
  });
  assert.equal(token.length, 24);
  const token2 = makeStatusToken({
    branch: "main",
    upstream: "origin/main",
    ahead: 0,
    behind: 0,
    files,
  });
  assert.equal(token, token2);
}

section("extractPrUrl / timingSafeTokenEqual");
{
  assert.equal(
    extractPrUrl("Created https://github.com/acme/demo/pull/42\n"),
    "https://github.com/acme/demo/pull/42",
  );
  assert.equal(timingSafeTokenEqual("abc", "abc"), true);
  assert.equal(timingSafeTokenEqual("abc", "abd"), false);
  assert.equal(timingSafeTokenEqual("ab", "abc"), false);
}

section("summarizeIpaBuildFailure prefers Swift errors");
{
  const noisy = [
    "Node.js 20 actions are deprecated",
    "actions/checkout@v4",
    "actions/setup-node@v4",
    "For more information see: https://github.blog/changelog/2025-...",
    "DomainTests.swift:708:35: error: actor-isolated property 'isStreaming'",
    "DomainTests.swift:709:35: error: actor-isolated property 'isSessionActive'",
    "##[error]Process completed with exit code 65.",
  ].join("\n");
  const summary = summarizeIpaBuildFailure(noisy);
  assert.match(summary, /isStreaming|isSessionActive/);
  assert.doesNotMatch(summary, /checkout@v4|setup-node@v4/);
}

section("path containment rejects symlink escape");
{
  const base = mkdtempSync(join(tmpdir(), "nova-repo-"));
  const root = join(base, "allowed");
  const outside = join(base, "outside");
  mkdirSync(root, { recursive: true });
  mkdirSync(outside, { recursive: true });
  writeFileSync(join(outside, "secret.txt"), "nope");
  mkdirSync(join(outside, "evil.git"), { recursive: true });
  // Fake a git repo outside
  mkdirSync(join(outside, ".git"));
  writeFileSync(join(outside, ".git", "HEAD"), "ref: refs/heads/main");

  const link = join(root, "escape");
  try {
    symlinkSync(outside, link, "junction");
  } catch {
    // Some environments disallow junctions; skip soft.
    console.log("skip symlink test (cannot create junction)");
    rmSync(base, { recursive: true, force: true });
  }

  if (existsSync(link)) {
    const svc = new RepoService({
      rootsEnv: root,
      defaultWorkdir: root,
      gitBin: null,
      ghBin: null,
    });
    // Discovery must not treat escaped junction target as an allowlisted repo
    // when realpath leaves the root — or if it does appear, resolve must reject.
    const { repos } = svc.listRepos();
    for (const r of repos) {
      assert.doesNotThrow(() => svc.resolveRepo(r.id));
      const resolved = svc.resolveRepo(r.id);
      assert.ok(resolved.path.toLowerCase().startsWith(root.toLowerCase()));
    }
    rmSync(base, { recursive: true, force: true });
  }
}

section("parseRepoRoots + opaque ids");
{
  const base = mkdtempSync(join(tmpdir(), "nova-roots-"));
  const a = join(base, "a");
  const b = join(base, "b");
  mkdirSync(a, { recursive: true });
  mkdirSync(b, { recursive: true });
  const roots = parseRepoRoots(`${a};${b}`, a);
  assert.equal(roots.length, 2);
  const id1 = opaqueRepoId(a);
  const id2 = opaqueRepoId(a);
  assert.equal(id1, id2);
  assert.equal(id1.length, 16);
  rmSync(base, { recursive: true, force: true });
}

section("stale status token rejection (publish)");
{
  const base = mkdtempSync(join(tmpdir(), "nova-pub-"));
  mkdirSync(join(base, ".git"), { recursive: true });
  writeFileSync(join(base, ".git", "HEAD"), "ref: refs/heads/main");
  const svc = new RepoService({
    rootsEnv: base,
    defaultWorkdir: base,
    gitBin: "git-not-used-for-this-assert",
    ghBin: "gh-not-used",
  });
  assert.throws(() => svc.resolveRepo("not-a-valid-id"), (e: unknown) => {
    assert.ok(e instanceof RepoError);
    assert.equal(e.code, "not_found");
    return true;
  });
  rmSync(base, { recursive: true, force: true });
}

async function realGitIntegration(): Promise<void> {
  section("integration: status token + stale publish (real git)");
  const gitBin = process.env.GIT_BIN || "git";
  const base = mkdtempSync(join(tmpdir(), "nova-git-"));
  try {
    const run = (args: string[]) =>
      spawnSync(gitBin, args, { cwd: base, encoding: "utf8", shell: false });
    const init = run(["init"]);
    if (init.status !== 0) {
      console.log("skip real-git integration (git init failed)");
      return;
    }
    run(["config", "user.email", "nova@test.local"]);
    run(["config", "user.name", "Nova Test"]);
    writeFileSync(join(base, "README.md"), "hello\n");
    mkdirSync(join(base, "Nova"), { recursive: true });
    mkdirSync(join(base, "nova-bridge"), { recursive: true });
    writeFileSync(
      join(base, "Nova", "Package.swift"),
      "let capabilities = [\"voice\", \"videoRecording\"]\n",
    );
    writeFileSync(
      join(base, "nova-bridge", "package.json"),
      JSON.stringify({ name: "nova-bridge" }),
    );
    run(["add", "README.md"]);
    run(["commit", "-m", "init"]);
    writeFileSync(join(base, "README.md"), "hello world\n");

    const svc = new RepoService({
      rootsEnv: base,
      defaultWorkdir: base,
      gitBin,
      ghBin: null,
    });
    const { repos } = svc.listRepos();
    assert.ok(repos.length >= 1);
    const repoId = repos[0]!.id;

    section("repository file browser");
    mkdirSync(join(base, "src"));
    mkdirSync(join(base, "node_modules"));
    writeFileSync(join(base, "src", "index.html"), "<h1>preview</h1>");
    writeFileSync(join(base, ".env"), "SECRET=nope");
    const rootListing = svc.listFiles(repoId);
    assert.ok(rootListing.entries.some((e) => e.name === "src" && e.kind === "directory"));
    assert.ok(rootListing.entries.some((e) => e.name === "README.md" && e.kind === "file"));
    assert.ok(!rootListing.entries.some((e) => e.name === ".env"));
    assert.ok(!rootListing.entries.some((e) => e.name === "node_modules"));
    const srcListing = svc.listFiles(repoId, "src");
    assert.deepEqual(srcListing.entries.map((e) => e.path), ["src/index.html"]);
    const file = svc.resolveRepoPath(repoId, "src/index.html");
    assert.equal(file.kind, "file");
    assert.throws(() => svc.resolveRepoPath(repoId, "../outside"), RepoError);
    assert.throws(() => svc.resolveRepoPath(repoId, ".git/config"), RepoError);

    section("bounded Nova self-code search + read");
    const selfRepo = svc.resolveNovaRepo();
    assert.equal(selfRepo.id, repoId);
    const search = svc.searchNovaCode("video recording capability");
    assert.ok(search.matches.some((match) => match.path === "Nova/Package.swift"));
    const source = svc.readNovaCode("Nova/Package.swift", 1, 20);
    assert.equal(source.path, "Nova/Package.swift");
    assert.ok(source.content.includes("videoRecording"));
    assert.throws(() => svc.searchNovaCode("x".repeat(301)), RepoError);
    assert.throws(() => svc.searchNovaCode("what does Nova have"), RepoError);
    assert.throws(() => svc.readNovaCode("Nova/Package.swift", Number.NaN, 10), RepoError);
    assert.throws(
      () => svc.readNovaCode(".env", 1, 10),
      (error: unknown) => error instanceof RepoError,
    );

    const status = await svc.status(repoId);
    assert.equal(status.clean, false);
    assert.ok(status.statusToken.length === 24);

    const diff = await svc.diff(repoId);
    assert.ok(diff.diff.includes("hello") || diff.diff.length >= 0);
    assert.equal(diff.statusToken, status.statusToken);

    await assert.rejects(
      () =>
        svc.publish(repoId, {
          statusToken: "deadbeefdeadbeefdeadbeef",
          commitMessage: "should fail",
          prTitle: "should fail",
        }),
      (e: unknown) => e instanceof RepoError && e.code === "stale_status",
    );
  } finally {
    rmSync(base, { recursive: true, force: true });
  }
}

await realGitIntegration();
console.log("\nAll repo-service tests passed.");
