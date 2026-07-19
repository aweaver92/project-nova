/**
 * Mirrors NovaDomain/ClientEnergyVAD.swift so we can prove the sticky-commit
 * fix on Windows without Swift. Keep in sync with the Swift struct.
 *
 * Run: node scripts/client-energy-vad.test.mjs
 */
import assert from "node:assert/strict";

function makeVad(overrides = {}) {
  // Keep defaults in sync with NovaDomain/ClientEnergyVAD.swift.
  return {
    minSpeechMs: 700,
    endSilenceMs: 650,
    maxSpeechMs: 4000,
    commitCooldownMs: 2000,
    minRingBytes: 1000,
    speechPeak: 0.1,
    speechRms: 0.035,
    speechZcr: 0.02,
    maxSpeechZcr: 0.35,
    quietPeak: 0.04,
    speechActive: false,
    speechStartedAt: null,
    quietSince: null,
    lastCommitAt: null,
    ...overrides,
  };
}

function isSpeechLike(vad, peak, rms, zcr) {
  return (
    peak >= vad.speechPeak &&
    rms >= vad.speechRms &&
    zcr >= vad.speechZcr &&
    zcr <= vad.maxSpeechZcr
  );
}

function recoverIfStuck(vad, now, timeoutMs = 4000) {
  if (vad.lastCommitAt == null) return;
  if (now - vad.lastCommitAt >= timeoutMs) vad.lastCommitAt = null;
}

function emitCommit(vad, now) {
  vad.speechActive = false;
  vad.speechStartedAt = null;
  vad.quietSince = null;
  vad.lastCommitAt = now;
  return "commit";
}

function observe(vad, { peak, zcr, rms = 0, ringBytes, now }) {
  recoverIfStuck(vad, now);

  const cooldownOk =
    vad.lastCommitAt == null || now - vad.lastCommitAt >= vad.commitCooldownMs;

  if (isSpeechLike(vad, peak, rms, zcr)) {
    if (!vad.speechActive) {
      vad.speechActive = true;
      vad.speechStartedAt = now;
    }
    vad.quietSince = null;
    if (
      vad.speechStartedAt != null &&
      now - vad.speechStartedAt >= vad.maxSpeechMs &&
      ringBytes >= vad.minRingBytes &&
      cooldownOk
    ) {
      return emitCommit(vad, now);
    }
    return "none";
  }

  if (!vad.speechActive) return "none";

  if (peak < vad.quietPeak) {
    if (vad.quietSince == null) vad.quietSince = now;
  } else {
    vad.quietSince = null;
    if (
      vad.speechStartedAt != null &&
      now - vad.speechStartedAt >= vad.maxSpeechMs &&
      rms >= vad.speechRms &&
      ringBytes >= vad.minRingBytes &&
      cooldownOk
    ) {
      return emitCommit(vad, now);
    }
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

  if (!cooldownOk) return "none";

  return emitCommit(vad, now);
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
  assert.equal(observe(vad, { peak: 0.2, zcr: 0.05, rms: 0.08, ringBytes: 2000, now: 0 }), "none");
  assert.equal(observe(vad, { peak: 0.2, zcr: 0.05, rms: 0.08, ringBytes: 4000, now: 450 }), "none");
  assert.equal(observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 5000, now: 800 }), "none"); // quiet starts
  assert.equal(observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 6000, now: 1500 }), "commit");
}

{
  // Subtle rustle: peak in the old sensitive band, low RMS — must not activate.
  const vad = makeVad();
  assert.equal(observe(vad, { peak: 0.08, zcr: 0.05, rms: 0.01, ringBytes: 8000, now: 0 }), "none");
  assert.equal(vad.speechActive, false);
  assert.equal(
    observe(vad, { peak: 0.08, zcr: 0.05, rms: 0.01, ringBytes: 9000, now: 800 }),
    "none"
  );
}

{
  // Sticky-flag regression: second turn must commit even without server ACK.
  const vad = makeVad();
  observe(vad, { peak: 0.3, zcr: 0.04, rms: 0.1, ringBytes: 2000, now: 0 });
  observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 4000, now: 800 }); // quiet starts
  assert.equal(observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 8000, now: 1500 }), "commit");

  const t2 = 3600; // past 2000ms commitCooldown
  observe(vad, { peak: 0.25, zcr: 0.05, rms: 0.09, ringBytes: 12000, now: t2 });
  observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 14000, now: t2 + 800 }); // quiet starts
  assert.equal(
    observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 16000, now: t2 + 1500 }),
    "commit",
    "second utterance must commit without transcript/response ACK"
  );
}

{
  const vad = makeVad();
  observe(vad, { peak: 0.3, zcr: 0.04, rms: 0.1, ringBytes: 2000, now: 0 });
  observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 4000, now: 800 });
  assert.equal(observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 8000, now: 1500 }), "commit");
  const mid = 1800;
  observe(vad, { peak: 0.3, zcr: 0.04, rms: 0.1, ringBytes: 9000, now: mid });
  observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 9500, now: mid + 800 });
  assert.equal(
    observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 10000, now: mid + 1500 }),
    "none",
    "cooldown must block immediate double-commit"
  );
}

{
  const vad = makeVad();
  observe(vad, { peak: 0.3, zcr: 0.04, rms: 0.1, ringBytes: 2000, now: 0 });
  observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 4000, now: 800 });
  assert.equal(observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 8000, now: 1500 }), "commit");
  unlockForRetry(vad);
  observe(vad, { peak: 0.3, zcr: 0.04, rms: 0.1, ringBytes: 9000, now: 1600 });
  observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 10000, now: 2400 });
  assert.equal(
    observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 12000, now: 3100 }),
    "commit"
  );
}

{
  const vad = makeVad();
  observe(vad, { peak: 0.3, zcr: 0.04, rms: 0.1, ringBytes: 2000, now: 0 });
  assert.equal(observe(vad, { peak: 0.01, zcr: 0, rms: 0, ringBytes: 100, now: 900 }), "none");
}

{
  // maxSpeech force-commit without needing silence.
  const vad = makeVad({ maxSpeechMs: 800 });
  assert.equal(observe(vad, { peak: 0.3, zcr: 0.05, rms: 0.1, ringBytes: 2000, now: 0 }), "none");
  assert.equal(
    observe(vad, { peak: 0.3, zcr: 0.05, rms: 0.1, ringBytes: 8000, now: 850 }),
    "commit",
    "maxSpeech must commit while still loud"
  );
}

{
  // Hysteresis band must not wedge forever when RMS is speech-like.
  const vad = makeVad({ maxSpeechMs: 800 });
  observe(vad, { peak: 0.3, zcr: 0.05, rms: 0.1, ringBytes: 2000, now: 0 });
  assert.equal(
    observe(vad, { peak: 0.07, zcr: 0.01, rms: 0.05, ringBytes: 8000, now: 900 }),
    "commit",
    "maxSpeech must escape quietPeak..speechPeak band"
  );
}

{
  // Ambient floor in hysteresis band without RMS must not force-commit.
  const vad = makeVad({ maxSpeechMs: 800 });
  observe(vad, { peak: 0.3, zcr: 0.05, rms: 0.1, ringBytes: 2000, now: 0 });
  assert.equal(
    observe(vad, { peak: 0.07, zcr: 0.01, rms: 0.01, ringBytes: 8000, now: 900 }),
    "none",
    "low-RMS hysteresis must not force-commit"
  );
}

function observeBargeIn(vad, { peak, rms = 0, zcr, now }) {
  const bargeInPeak = vad.bargeInPeak ?? 0.14;
  const bargeInRms = vad.bargeInRms ?? 0.05;
  const bargeInHoldMs = vad.bargeInHoldMs ?? 320;
  if (
    peak >= bargeInPeak &&
    rms >= bargeInRms &&
    zcr >= vad.speechZcr &&
    zcr <= vad.maxSpeechZcr
  ) {
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
  vad.bargeInPeak = 0.14;
  vad.bargeInRms = 0.05;
  vad.bargeInHoldMs = 320;
  vad.bargeInSince = null;
  assert.equal(observeBargeIn(vad, { peak: 0.2, rms: 0.08, zcr: 0.05, now: 0 }), false);
  assert.equal(observeBargeIn(vad, { peak: 0.2, rms: 0.08, zcr: 0.05, now: 200 }), false);
  assert.equal(observeBargeIn(vad, { peak: 0.2, rms: 0.08, zcr: 0.05, now: 330 }), true);
  // Quiet resets hold.
  assert.equal(observeBargeIn(vad, { peak: 0.01, rms: 0, zcr: 0, now: 400 }), false);
  assert.equal(observeBargeIn(vad, { peak: 0.2, rms: 0.08, zcr: 0.05, now: 410 }), false);
}

console.log("✅ client-energy-vad.test.mjs PASS");
