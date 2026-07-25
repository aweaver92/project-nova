import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

/// Starts / updates / ends the app's Live Activities. Every method is safe to
/// call on any platform: when ActivityKit is unavailable (macOS test host) or
/// Live Activities are disabled by the user, the calls are no-ops.
///
/// Callers drive these idempotently from their 1s refresh loops — `sync*`
/// starts an activity if none exists and only pushes an update when the visible
/// content actually changes, so per-second refreshes stay cheap.
@MainActor
public final class LiveActivityCoordinator {
    public static let shared = LiveActivityCoordinator()

    public init() {}

    #if canImport(ActivityKit)
    private var restActivity: Activity<RestTimerAttributes>?
    private var restKey: String?
    private var cookActivity: Activity<CookStepAttributes>?
    private var cookKey: String?

    private var activitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }
    #endif

    // MARK: - Rest timer (Max)

    public func syncRest(workoutTitle: String, exercise: String, endsAt: Date, totalSeconds: Int) {
        #if canImport(ActivityKit)
        guard activitiesEnabled else { return }
        let key = "\(exercise)|\(Int(endsAt.timeIntervalSince1970))|\(totalSeconds)"
        guard key != restKey else { return }
        let state = RestTimerAttributes.ContentState(
            exercise: exercise,
            endsAt: endsAt,
            totalSeconds: totalSeconds
        )
        let content = ActivityContent(state: state, staleDate: endsAt.addingTimeInterval(15))
        if let activity = restActivity {
            restKey = key
            Task { await activity.update(content) }
        } else {
            do {
                restActivity = try Activity.request(
                    attributes: RestTimerAttributes(workoutTitle: workoutTitle),
                    content: content,
                    pushType: nil
                )
                restKey = key
            } catch {
                restActivity = nil
                restKey = nil
            }
        }
        #endif
    }

    public func endRest() {
        #if canImport(ActivityKit)
        guard let activity = restActivity else { return }
        restActivity = nil
        restKey = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        #endif
    }

    // MARK: - Cook mode (Remy)

    public func syncCook(recipeTitle: String, stepIndex: Int, stepCount: Int, stepText: String, timerEndsAt: Date?) {
        #if canImport(ActivityKit)
        guard activitiesEnabled else { return }
        let timerKey = timerEndsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        let key = "\(stepIndex)|\(stepCount)|\(stepText.hashValue)|\(timerKey)"
        guard key != cookKey else { return }
        let state = CookStepAttributes.ContentState(
            stepIndex: stepIndex,
            stepCount: stepCount,
            stepText: stepText,
            timerEndsAt: timerEndsAt
        )
        let staleDate = timerEndsAt?.addingTimeInterval(15)
        let content = ActivityContent(state: state, staleDate: staleDate)
        if let activity = cookActivity {
            cookKey = key
            Task { await activity.update(content) }
        } else {
            do {
                cookActivity = try Activity.request(
                    attributes: CookStepAttributes(recipeTitle: recipeTitle),
                    content: content,
                    pushType: nil
                )
                cookKey = key
            } catch {
                cookActivity = nil
                cookKey = nil
            }
        }
        #endif
    }

    public func endCook() {
        #if canImport(ActivityKit)
        guard let activity = cookActivity else { return }
        cookActivity = nil
        cookKey = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        #endif
    }
}
