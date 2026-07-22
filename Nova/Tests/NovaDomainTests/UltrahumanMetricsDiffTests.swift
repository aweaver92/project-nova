import XCTest
@testable import NovaDomain

final class UltrahumanMetricsDiffTests: XCTestCase {
    func testParseFlatDailyMetrics() throws {
        let json = """
        {
          "recovery": 72,
          "recovery_index": 68,
          "sleep_score": 81,
          "total_sleep": 25200,
          "avg_sleep_hrv": 54,
          "night_rhr": 48,
          "movement_index": 70,
          "steps": 8421,
          "vo2_max": 48.5
        }
        """.data(using: .utf8)!

        let snap = try XCTUnwrap(
            UltrahumanMetricsDiff.parseDailyMetrics(json, sourceDate: "2026-07-21")
        )
        XCTAssertEqual(snap.sourceDate, "2026-07-21")
        XCTAssertEqual(snap.recoveryScore, 72)
        XCTAssertEqual(snap.recoveryIndex, 68)
        XCTAssertEqual(snap.primaryRecovery, 68)
        XCTAssertEqual(snap.sleepScore, 81)
        XCTAssertEqual(snap.totalSleepMinutes, 420, accuracy: 0.01)
        XCTAssertEqual(snap.averageSleepHRV, 54)
        XCTAssertEqual(snap.nightRestingHR, 48)
        XCTAssertEqual(snap.steps, 8421)
        XCTAssertEqual(snap.vo2Max, 48.5)
        XCTAssertTrue(snap.advice.contains("train") || snap.advice.contains("warm"))
    }

    func testParseWrappedAndNestedSleep() throws {
        let json = """
        {
          "data": {
            "recovery_index": 82,
            "sleep": {
              "score": 88,
              "total_sleep": 7.5,
              "avg_hrv": 61,
              "rhr": 47
            },
            "hrv": 55
          }
        }
        """.data(using: .utf8)!

        let snap = try XCTUnwrap(
            UltrahumanMetricsDiff.parseDailyMetrics(json, sourceDate: "2026-07-20")
        )
        XCTAssertEqual(snap.recoveryIndex, 82)
        XCTAssertEqual(snap.sleepScore, 88)
        XCTAssertEqual(snap.totalSleepMinutes, 450, accuracy: 0.01)
        XCTAssertEqual(snap.averageSleepHRV, 61)
        XCTAssertEqual(snap.nightRestingHR, 47)
        XCTAssertTrue(snap.advice.lowercased().contains("recovered") || snap.advice.lowercased().contains("green"))
    }

    func testAdviceLowRecovery() {
        let snap = RingReadinessSnapshot(sourceDate: "2026-07-21", recoveryIndex: 32, sleepScore: 70)
        let advice = UltrahumanMetricsDiff.readinessAdvice(snap)
        XCTAssertTrue(advice.lowercased().contains("rest") || advice.lowercased().contains("deload"))
    }

    func testAdvicePoorSleep() {
        let snap = RingReadinessSnapshot(sourceDate: "2026-07-21", recoveryIndex: 70, sleepScore: 40)
        let advice = UltrahumanMetricsDiff.readinessAdvice(snap)
        XCTAssertTrue(advice.lowercased().contains("sleep") || advice.lowercased().contains("moderate"))
    }

    func testDateStringFormatsLocalDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = cal.date(from: DateComponents(year: 2026, month: 3, day: 5))!
        XCTAssertEqual(UltrahumanMetricsDiff.dateString(for: date, calendar: cal), "2026-03-05")
    }
}
