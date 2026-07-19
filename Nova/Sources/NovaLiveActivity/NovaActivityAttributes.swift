import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Live Activity for Max's rest timer. `endsAt` lets the lock-screen / Dynamic
/// Island widget count down on its own without per-second updates.
public struct RestTimerAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var exercise: String
        public var endsAt: Date
        public var totalSeconds: Int

        public init(exercise: String, endsAt: Date, totalSeconds: Int) {
            self.exercise = exercise
            self.endsAt = endsAt
            self.totalSeconds = totalSeconds
        }
    }

    public var workoutTitle: String

    public init(workoutTitle: String) {
        self.workoutTitle = workoutTitle
    }
}

/// Live Activity for Remy's cook mode: the current step plus an optional running
/// step timer.
public struct CookStepAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var stepIndex: Int
        public var stepCount: Int
        public var stepText: String
        public var timerEndsAt: Date?

        public init(stepIndex: Int, stepCount: Int, stepText: String, timerEndsAt: Date?) {
            self.stepIndex = stepIndex
            self.stepCount = stepCount
            self.stepText = stepText
            self.timerEndsAt = timerEndsAt
        }
    }

    public var recipeTitle: String

    public init(recipeTitle: String) {
        self.recipeTitle = recipeTitle
    }
}
#endif
