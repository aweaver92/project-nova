import XCTest
@testable import NovaDomain

final class ClientEnergyVADTests: XCTestCase {
    private func makeVAD() -> ClientEnergyVAD {
        var vad = ClientEnergyVAD()
        // Tight timings so tests stay fast and deterministic.
        vad.minSpeech = .milliseconds(400)
        vad.endSilence = .milliseconds(550)
        vad.commitCooldown = .milliseconds(1500)
        vad.minRingBytes = 1000
        return vad
    }

    func testCommitsAfterSpeechThenSilence() {
        var vad = makeVAD()
        let t0 = ContinuousClock.Instant.now

        XCTAssertEqual(
            vad.observe(peak: 0.2, zcr: 0.05, ringBytes: 2000, now: t0),
            .none
        )
        XCTAssertEqual(
            vad.observe(peak: 0.2, zcr: 0.05, ringBytes: 4000, now: t0.advanced(by: .milliseconds(450))),
            .none
        )
        // Quiet timer starts here.
        XCTAssertEqual(
            vad.observe(peak: 0.01, zcr: 0.0, ringBytes: 5000, now: t0.advanced(by: .milliseconds(500))),
            .none
        )
        // End silence elapsed + min speech → commit.
        XCTAssertEqual(
            vad.observe(peak: 0.01, zcr: 0.0, ringBytes: 6000, now: t0.advanced(by: .milliseconds(1100))),
            .commit
        )
    }

    func testStickyFlagBug_secondUtteranceStillCommitsWithoutAck() {
        // Reproduces the Listen regression: first commit never got transcript/
        // response.ended, so the old `didClientCommitFallback` blocked forever.
        var vad = makeVAD()
        let t0 = ContinuousClock.Instant.now

        // Turn 1
        _ = vad.observe(peak: 0.3, zcr: 0.04, ringBytes: 2000, now: t0)
        _ = vad.observe(peak: 0.01, zcr: 0, ringBytes: 4000, now: t0.advanced(by: .milliseconds(500)))
        XCTAssertEqual(
            vad.observe(peak: 0.01, zcr: 0, ringBytes: 8000, now: t0.advanced(by: .milliseconds(1200))),
            .commit
        )

        // No acknowledgeTurnFinished — server silent. After cooldown, turn 2 must commit.
        let t2 = t0.advanced(by: .milliseconds(2800))
        _ = vad.observe(peak: 0.25, zcr: 0.05, ringBytes: 12_000, now: t2)
        _ = vad.observe(peak: 0.01, zcr: 0, ringBytes: 14_000, now: t2.advanced(by: .milliseconds(400)))
        XCTAssertEqual(
            vad.observe(peak: 0.01, zcr: 0, ringBytes: 16_000, now: t2.advanced(by: .milliseconds(1000))),
            .commit
        )
    }

    func testCooldownBlocksImmediateDoubleCommit() {
        var vad = makeVAD()
        let t0 = ContinuousClock.Instant.now
        _ = vad.observe(peak: 0.3, zcr: 0.04, ringBytes: 2000, now: t0)
        _ = vad.observe(peak: 0.01, zcr: 0, ringBytes: 4000, now: t0.advanced(by: .milliseconds(500)))
        XCTAssertEqual(
            vad.observe(peak: 0.01, zcr: 0, ringBytes: 8000, now: t0.advanced(by: .milliseconds(1200))),
            .commit
        )

        // Same silence window inside cooldown — must not re-commit.
        let mid = t0.advanced(by: .milliseconds(1500))
        _ = vad.observe(peak: 0.3, zcr: 0.04, ringBytes: 9000, now: mid)
        _ = vad.observe(peak: 0.01, zcr: 0, ringBytes: 9500, now: mid.advanced(by: .milliseconds(400)))
        XCTAssertEqual(
            vad.observe(peak: 0.01, zcr: 0, ringBytes: 10_000, now: mid.advanced(by: .milliseconds(1000))),
            .none
        )
    }

    func testUnlockForRetryAllowsImmediateNextCommit() {
        var vad = makeVAD()
        let t0 = ContinuousClock.Instant.now
        _ = vad.observe(peak: 0.3, zcr: 0.04, ringBytes: 2000, now: t0)
        _ = vad.observe(peak: 0.01, zcr: 0, ringBytes: 4000, now: t0.advanced(by: .milliseconds(500)))
        XCTAssertEqual(
            vad.observe(peak: 0.01, zcr: 0, ringBytes: 8000, now: t0.advanced(by: .milliseconds(1200))),
            .commit
        )
        vad.unlockForRetry()

        let t1 = t0.advanced(by: .milliseconds(1300))
        _ = vad.observe(peak: 0.3, zcr: 0.04, ringBytes: 9000, now: t1)
        _ = vad.observe(peak: 0.01, zcr: 0, ringBytes: 10_000, now: t1.advanced(by: .milliseconds(400)))
        XCTAssertEqual(
            vad.observe(peak: 0.01, zcr: 0, ringBytes: 12_000, now: t1.advanced(by: .milliseconds(1000))),
            .commit
        )
    }

    func testRecoverIfStuckClearsCooldownAfterTimeout() {
        var vad = makeVAD()
        let t0 = ContinuousClock.Instant.now
        _ = vad.observe(peak: 0.3, zcr: 0.04, ringBytes: 2000, now: t0)
        _ = vad.observe(peak: 0.01, zcr: 0, ringBytes: 4000, now: t0.advanced(by: .milliseconds(500)))
        XCTAssertEqual(
            vad.observe(peak: 0.01, zcr: 0, ringBytes: 8000, now: t0.advanced(by: .milliseconds(1200))),
            .commit
        )

        // 4s stuck recovery fires inside observe.
        let tStuck = t0.advanced(by: .seconds(6))
        _ = vad.observe(peak: 0.3, zcr: 0.04, ringBytes: 9000, now: tStuck)
        _ = vad.observe(peak: 0.01, zcr: 0, ringBytes: 10_000, now: tStuck.advanced(by: .milliseconds(400)))
        XCTAssertEqual(
            vad.observe(peak: 0.01, zcr: 0, ringBytes: 12_000, now: tStuck.advanced(by: .milliseconds(1000))),
            .commit
        )
    }

    func testRejectsShortSpeechAndTinyRing() {
        var vad = makeVAD()
        let t0 = ContinuousClock.Instant.now
        _ = vad.observe(peak: 0.3, zcr: 0.04, ringBytes: 100, now: t0)
        // Quiet after only 100ms of speech + tiny ring → no commit.
        XCTAssertEqual(
            vad.observe(peak: 0.01, zcr: 0, ringBytes: 100, now: t0.advanced(by: .milliseconds(700))),
            .none
        )
    }
}
