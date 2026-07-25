import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BaselineService } from "./baseline-service.js";
import { RepoError } from "./repo-service.js";

const root = mkdtempSync(join(tmpdir(), "nova-baseline-"));
const state = mkdtempSync(join(tmpdir(), "nova-baseline-state-"));
const repoId = "abcdef0123456789";

try {
  writeFileSync(join(root, "kept-dirty.txt"), "user work\n");
  writeFileSync(join(root, "will-edit.txt"), "before\n");
  mkdirSync(join(root, "src"));

  const svc = new BaselineService(state);
  const created = svc.create(repoId, root, ["kept-dirty.txt", "will-edit.txt"]);
  assert.equal(created.fileCount, 2);

  // Pre-existing dirty left alone; agent edits another file and adds a new one.
  writeFileSync(join(root, "will-edit.txt"), "after\n");
  writeFileSync(join(root, "src/new.html"), "<h1>hi</h1>\n");
  writeFileSync(join(root, "secret.bin"), Buffer.from([0, 1, 2, 3, 0, 5]));

  const review = svc.review(repoId, created.baselineId, root, [
    "kept-dirty.txt",
    "will-edit.txt",
    "src/new.html",
    "secret.bin",
  ]);
  const paths = review.files.map((f) => f.path).sort();
  assert.deepEqual(paths, ["secret.bin", "src/new.html", "will-edit.txt"]);
  assert.ok(!paths.includes("kept-dirty.txt"), "pre-existing dirty excluded");
  assert.equal(review.files.find((f) => f.path === "will-edit.txt")?.change, "modified");
  assert.equal(review.files.find((f) => f.path === "src/new.html")?.change, "added");
  assert.equal(review.files.find((f) => f.path === "secret.bin")?.change, "added");
  assert.equal(review.files.find((f) => f.path === "secret.bin")?.binary, true);

  const token = review.files.find((f) => f.path === "will-edit.txt")!.contentToken;
  svc.keep(repoId, created.baselineId, ["src/new.html"]);
  const afterKeep = svc.review(repoId, created.baselineId, root, [
    "kept-dirty.txt",
    "will-edit.txt",
    "src/new.html",
    "secret.bin",
  ]);
  assert.equal(afterKeep.files.find((f) => f.path === "src/new.html")?.kept, true);

  svc.restore(repoId, created.baselineId, root, ["will-edit.txt"], {
    "will-edit.txt": token,
  });
  assert.equal(readFileSync(join(root, "will-edit.txt"), "utf8"), "before\n");
  assert.equal(readFileSync(join(root, "kept-dirty.txt"), "utf8"), "user work\n");

  // Concurrent edit rejection.
  writeFileSync(join(root, "will-edit.txt"), "race\n");
  assert.throws(
    () =>
      svc.restore(repoId, created.baselineId, root, ["will-edit.txt"], {
        "will-edit.txt": token,
      }),
    (e: unknown) => e instanceof RepoError && e.code === "stale_review",
  );

  assert.throws(
    () => svc.create(repoId, root, ["../escape.txt"]),
    (e: unknown) => e instanceof RepoError && e.code === "invalid_path",
  );

  console.log("baseline-service.test.ts: ok");
} finally {
  rmSync(root, { recursive: true, force: true });
  rmSync(state, { recursive: true, force: true });
}
