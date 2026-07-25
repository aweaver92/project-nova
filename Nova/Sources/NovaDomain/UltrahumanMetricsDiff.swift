import Foundation

/// Normalized Ultrahuman Ring readiness for Max coaching + Training UI.
public struct RingReadinessSnapshot: Sendable, Equatable, Codable {
    public var sourceDate: String
    public var fetchedAt: Date
    public var recoveryScore: Double?
    public var recoveryIndex: Double?
    public var sleepScore: Double?
    public var totalSleepMinutes: Double?
    public var averageSleepHRV: Double?
    public var hrv: Double?
    public var nightRestingHR: Double?
    public var movementIndex: Double?
    public var steps: Double?
    public var vo2Max: Double?
    public var advice: String

    public init(
        sourceDate: String,
        fetchedAt: Date = Date(),
        recoveryScore: Double? = nil,
        recoveryIndex: Double? = nil,
        sleepScore: Double? = nil,
        totalSleepMinutes: Double? = nil,
        averageSleepHRV: Double? = nil,
        hrv: Double? = nil,
        nightRestingHR: Double? = nil,
        movementIndex: Double? = nil,
        steps: Double? = nil,
        vo2Max: Double? = nil,
        advice: String = ""
    ) {
        self.sourceDate = sourceDate
        self.fetchedAt = fetchedAt
        self.recoveryScore = recoveryScore
        self.recoveryIndex = recoveryIndex
        self.sleepScore = sleepScore
        self.totalSleepMinutes = totalSleepMinutes
        self.averageSleepHRV = averageSleepHRV
        self.hrv = hrv
        self.nightRestingHR = nightRestingHR
        self.movementIndex = movementIndex
        self.steps = steps
        self.vo2Max = vo2Max
        self.advice = advice
    }

    /// Best single recovery number for UI (prefer recovery_index, then recovery).
    public var primaryRecovery: Double? {
        recoveryIndex ?? recoveryScore
    }

    public var spokenSummary: String {
        var parts: [String] = ["Ring data for \(sourceDate)."]
        if let r = primaryRecovery {
            parts.append(String(format: "Recovery %.0f.", r))
        }
        if let s = sleepScore {
            parts.append(String(format: "Sleep score %.0f.", s))
        }
        if let h = averageSleepHRV ?? hrv {
            parts.append(String(format: "HRV %.0f.", h))
        }
        if !advice.isEmpty {
            parts.append(advice)
        }
        return parts.joined(separator: " ")
    }
}

/// Pure helpers: parse Ultrahuman daily_metrics JSON and coach readiness bands.
public enum UltrahumanMetricsDiff {
    public static func dateString(for date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let y = parts.year ?? 1970
        let m = parts.month ?? 1
        let d = parts.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    public static func parseDailyMetrics(
        _ data: Data,
        sourceDate: String,
        fetchedAt: Date = Date()
    ) -> RingReadinessSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let dict = unwrapObject(root)
        guard !dict.isEmpty else { return nil }

        var snapshot = RingReadinessSnapshot(
            sourceDate: sourceDate,
            fetchedAt: fetchedAt,
            recoveryScore: number(in: dict, keys: ["recovery", "recovery_score", "Recovery"]),
            recoveryIndex: number(in: dict, keys: ["recovery_index", "RecoveryIndex", "recoveryIndex"]),
            sleepScore: number(in: dict, keys: ["sleep_score", "SleepScore", "sleepScore"]),
            totalSleepMinutes: totalSleepMinutes(in: dict),
            averageSleepHRV: number(in: dict, keys: ["avg_sleep_hrv", "average_sleep_hrv", "AvgSleepHRV"]),
            hrv: number(in: dict, keys: ["hrv", "HRV"]),
            nightRestingHR: number(in: dict, keys: [
                "night_rhr", "sleep_rhr", "NightRHR", "sleep_resting_hr"
            ]),
            movementIndex: number(in: dict, keys: ["movement_index", "MovementIndex", "movementIndex"]),
            steps: number(in: dict, keys: ["steps", "Steps", "step_count"]),
            vo2Max: number(in: dict, keys: ["vo2_max", "VO2Max", "vo2Max"])
        )
        // Nested sleep object often holds score / duration / HRV.
        if let sleep = nestedObject(in: dict, keys: ["sleep", "Sleep"]) {
            if snapshot.sleepScore == nil {
                snapshot.sleepScore = number(in: sleep, keys: ["score", "sleep_score", "SleepScore"])
            }
            if snapshot.totalSleepMinutes == nil {
                snapshot.totalSleepMinutes = totalSleepMinutes(in: sleep)
            }
            if snapshot.averageSleepHRV == nil {
                snapshot.averageSleepHRV = number(in: sleep, keys: ["avg_hrv", "hrv", "avg_sleep_hrv"])
            }
            if snapshot.nightRestingHR == nil {
                snapshot.nightRestingHR = number(in: sleep, keys: ["rhr", "resting_hr", "night_rhr"])
            }
        }
        if let recovery = nestedObject(in: dict, keys: ["recovery", "Recovery"]) {
            // Some payloads nest scores under a recovery object (and top-level recovery is that object).
            if snapshot.recoveryScore == nil {
                snapshot.recoveryScore = number(in: recovery, keys: ["score", "recovery", "value"])
            }
            if snapshot.recoveryIndex == nil {
                snapshot.recoveryIndex = number(in: recovery, keys: ["index", "recovery_index", "value"])
            }
        }
        snapshot.advice = readinessAdvice(snapshot)
        return snapshot
    }

    public static func readinessAdvice(_ snapshot: RingReadinessSnapshot) -> String {
        let recovery = snapshot.primaryRecovery
        let sleep = snapshot.sleepScore

        if let recovery, recovery < 40 {
            return "Recovery is low — favor rest, technique work, or a light deload. Skip heavy PRs today."
        }
        if let sleep, sleep < 55 {
            return "Sleep looks rough — keep volume moderate and prioritize form over load."
        }
        if let recovery, recovery < 60 {
            return "Recovery is only fair — train, but trim a set or two and watch bar speed."
        }
        if let recovery, recovery >= 75, let sleep, sleep >= 70 {
            return "Ring says you're recovered — green light for progressive overload if you feel good."
        }
        if recovery == nil, sleep == nil {
            return "Ring metrics were thin for this day — coach from how you feel and recent sessions."
        }
        return "Solid enough to train — warm up thoroughly and adjust if anything feels off."
    }

    // MARK: - Private parse helpers

    private static func unwrapObject(_ root: Any) -> [String: Any] {
        if let dict = root as? [String: Any] {
            // Common wrappers: { data: {...} } or { metrics: {...} }
            if let data = dict["data"] as? [String: Any] { return flatten(data, parent: dict) }
            if let metrics = dict["metrics"] as? [String: Any] { return flatten(metrics, parent: dict) }
            if let result = dict["result"] as? [String: Any] { return flatten(result, parent: dict) }
            return dict
        }
        return [:]
    }

    private static func flatten(_ primary: [String: Any], parent: [String: Any]) -> [String: Any] {
        var out = parent
        for (k, v) in primary { out[k] = v }
        return out
    }

    private static func nestedObject(in root: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let obj = root[key] as? [String: Any] { return obj }
        }
        return nil
    }

    private static func number(in root: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = root[key] as? Double { return value }
            if let value = root[key] as? Int { return Double(value) }
            if let value = root[key] as? NSNumber { return value.doubleValue }
            if let value = root[key] as? String,
               let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
            // Nested { value: N }
            if let obj = root[key] as? [String: Any] {
                if let nested = number(in: obj, keys: ["value", "score", "avg", "average", "total"]) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func totalSleepMinutes(in root: [String: Any]) -> Double? {
        if let minutes = number(in: root, keys: [
            "total_sleep_minutes", "totalSleepMinutes", "sleep_minutes"
        ]) {
            return minutes
        }
        if let seconds = number(in: root, keys: ["total_sleep", "totalSleep", "sleep_duration"]) {
            // UH payloads vary: seconds (~25k), minutes (~420), or hours (~7.5).
            if seconds > 800 { return seconds / 60.0 }
            if seconds <= 24 { return seconds * 60.0 }
            return seconds
        }
        if let hours = number(in: root, keys: ["total_sleep_hours", "sleep_hours"]), hours <= 24 {
            return hours * 60.0
        }
        return nil
    }
}
