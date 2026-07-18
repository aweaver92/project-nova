/**
 * Mirrors NovaDomain/ClientEnergyVAD.swift so we can prove the sticky-commit
 * fix on Windows without Swift. Keep in sync with the Swift struct.
 *
 * Run: node scripts/client-energy-vad.test.mjs
 */
import assert from "node:assert/strict";

function makeVad(overrides = {}) {
  return {
    minSpeechMs: 400,
    endSilenceMs: 550,
    commitCooldownMs: 1500,
    minRingBytes: 1000,
    speechPeak: 0.05,
    speechZcr: 0.015,
    quietPeak: 0.025,
    speechActive: false,
    speechStartedAt: null,
    quietSince: null,
    lastCommitAt: null,
    ...overrides,
  };
}

function recoverIfStuck(vad, now, timeoutMs = 4000) {
  if (vad.lastCommitAt == null) return;
  if (now - vad.lastCommitAt >= timeoutMs) vad.lastCommitAt = null;
}

function observe(vad, { peak, zcr, ringBytes, now }) {
  recoverIfStuck(vad, now);

  if (peak >= vad.speechPeak && zcr >= vad.speechZcr) {
    if (!vad.speechActive) {
      vad.speechActive = true;
      vad.speechStartedAt = now;
    }
    vad.quietSince = null;
    return "none";
  }

  if (!vad.speechActive) return "none";

  if (peak < vad.quietPeak) {
    if (vad.quietSince == null) vad.quietSince = now;
  } else {
    vad.quietSince = null;
    return "none";
  }

  if (
    vad.quietSince == null ||
    now - vad.quietSince < vad.endSilenceMs ||
    vad.speechStartedAt == null ||
    now - vad.speechStartedAt < vad.minSpeechMs ||
    ringBytes < vad.minRingBytes
  ) {
    return "none";
  }

  if (vad.lastCommitAt != null && now - vad.lastCommitAt < vad.commitCooldownMs) {
    return "none";
  }

  vad.speechActive = false;
  vad.speechStartedAt = null;
  vad.quietSince = null;
  vad.lastCommitAt = now;
  return "commit";
}

function unlockForRetry(vad) {
  vad.speechActive = false;
  vad.speechStartedAt = null;
  vad.quietSince = null;
  vad.lastCommitAt = null;
}

// --- tests ---

{
  const vad = makeVad();
  assert.equal(observe(vad, { peak: 0.2, zcr: 0.05, ringBytes: 2000, now: 0 }), "none");
  assert.equal(observe(vad, { peak: 0.2, zcr: 0.05, ringBytes: 4000, now: 450 }), "none");
  assert.equal(observe(vad, { peak: 0.01, zcr: 0, ringBytes: 5000, now: 500 }), "none"); // quiet starts
  assert.equal(observe(vad, { peak: 0.01, zcr: 0, ringBytes: 6000, now: 1100 }), "commit");
}

{
  // Sticky-flag regression: second turn must commit even without server ACK.
  const vad = makeVad();
  observe(vad, { peak: 0.3, zcr: 0.04, ringBytes: 2000, now: 0 });
  observe(vad, { peak: 0.01, zcr: 0, ringBytes: 4000, now: 500 }); // quiet starts
  assert.equal(observe(vad, { peak: 0.01, zcr: 0, ringBytes: 8000, now: 1200 }), "commit");

  const t2 = 2800;
  observe(vad, { peak: 0.25, zcr: 0.05, ringBytes: 12000, now: t2 });
  observe(vad, { peak: 0.01, zcr: 0, ringBytes: 14000, now: t2 + 400 }); // quiet starts
  assert.equal(
    observe(vad, { peak: 0.01, zcr: 0, ringBytes: 16000, now: t2 + 1000 }),
    "commit",
    "second utterance must commit without transcript/response ACK"
  );
}

{
  const vad = makeVad();
  observe(vad, { peak: 0.3, zcr: 0.04, ringBytes: 2000, now: 0 });
  observe(vad, { peak: 0.01, zcr: 0, ringBytes: 4000, now: 500 });
  assert.equal(observe(vad, { peak: 0.01, zcr: 0, ringBytes: 8000, now: 1200 }), "commit");
  const mid = 1500;
  observe(vad, { peak: 0.3, zcr: 0.04, ringBytes: 9000, now: mid });
  observe(vad, { peak: 0.01, zcr: 0, ringBytes: 9500, now: mid + 400 });
  assert.equal(
    observe(vad, { peak: 0.01, zcr: 0, ringBytes: 10000, now: mid + 1000 }),
    "none",
    "cooldown must block immediate double-commit"
  );
}

{
  const vad = makeVad();
  observe(vad, { peak: 0.3, zcr: 0.04, ringBytes: 2000, now: 0 });
  observe(vad, { peak: 0.01, zcr: 0, ringBytes: 4000, now: 500 });
  assert.equal(observe(vad, { peak: 0.01, zcr: 0, ringBytes: 8000, now: 1200 }), "commit");
  unlockForRetry(vad);
  observe(vad, { peak: 0.3, zcr: 0.04, ringBytes: 9000, now: 1300 });
  observe(vad, { peak: 0.01, zcr: 0, ringBytes: 10000, now: 1700 });
  assert.equal(
    observe(vad, { peak: 0.01, zcr: 0, ringBytes: 12000, now: 2300 }),
    "commit"
  );
}

{
  const vad = makeVad();
  observe(vad, { peak: 0.3, zcr: 0.04, ringBytes: 2000, now: 0 });
  assert.equal(observe(vad, { peak: 0.01, zcr: 0, ringBytes: 100, now: 700 }), "none");
}

function observeBargeIn(vad, { peak, zcr, now }) {
  const bargeInPeak = vad.bargeInPeak ?? 0.12;
  const bargeInHoldMs = vad.bargeInHoldMs ?? 280;
  if (peak >= bargeInPeak && zcr >= vad.speechZcr) {
    if (vad.bargeInSince == null) vad.bargeInSince = now;
    if (now - vad.bargeInSince >= bargeInHoldMs) {
      vad.bargeInSince = null;
      return true;
    }
    return false;
  }
  vad.bargeInSince = null;
  return false;
}

{
  const vad = makeVad();
  vad.bargeInPeak = 0.12;
  vad.bargeInHoldMs = 280;
  vad.bargeInSince = null;
  assert.equal(observeBargeIn(vad, { peak: 0.2, zcr: 0.05, now: 0 }), false);
  assert.equal(observeBargeIn(vad, { peak: 0.2, zcr: 0.05, now: 200 }), false);
  assert.equal(observeBargeIn(vad, { peak: 0.2, zcr: 0.05, now: 300 }), true);
  // Quiet resets hold.
  assert.equal(observeBargeIn(vad, { peak: 0.01, zcr: 0, now: 400 }), false);
  assert.equal(observeBargeIn(vad, { peak: 0.2, zcr: 0.05, now: 410 }), false);
}

console.log("✅ client-energy-vad.test.mjs PASS");
