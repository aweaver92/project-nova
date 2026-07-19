import Foundation
import NovaDomain
import Observation

@MainActor
@Observable
public final class SageWellnessViewModel {
    public private(set) var recent: [WellnessCheckin] = []
    public private(set) var breathTimers: [ActiveTimer] = []
    public private(set) var statusMessage: String = ""
    public var draftMood: Int = 3
    public var draftNote: String = ""

    /// True while Wellness is on-screen (drives polling for voice-written check-ins).
    public private(set) var isScreenVisible = false

    private let store: any WellnessStoring
    private let timers: any TimerScheduling
    private var pollTask: Task<Void, Never>?

    public init(store: any WellnessStoring, timers: any TimerScheduling) {
        self.store = store
        self.timers = timers
    }

    public var averageMoodLabel: String {
        guard !recent.isEmpty else { return "No check-ins yet" }
        let avg = Double(recent.map(\.mood).reduce(0, +)) / Double(recent.count)
        return String(format: "Avg mood %.1f / 5", avg)
    }

    public var breathRemainingSeconds: Int {
        breathTimers.map(\.remainingSeconds).max() ?? 0
    }

    public var hasActiveBreathingTimer: Bool {
        breathRemainingSeconds > 0
    }

    /// Fresh check-in (2h) or an active breathing timer — high-signal resume only.
    public var hasResumeSignal: Bool {
        hasActiveBreathingTimer || hasFreshCheckin
    }

    public var hasFreshCheckin: Bool {
        guard let latest = recent.first else { return false }
        return Date().timeIntervalSince(latest.at) < 2 * 60 * 60
    }

    public var resumeSubtitle: String {
        if hasActiveBreathingTimer {
            return "Breathing · \(breathRemainingSeconds)s"
        }
        if hasFreshCheckin {
            return "Recent check-in"
        }
        if recent.isEmpty {
            return "Check-ins and breath timers"
        }
        return "\(recent.count) recent check-ins"
    }

    public func setScreenVisible(_ visible: Bool) {
        isScreenVisible = visible
        updatePolling()
    }

    public func load() async {
        await refresh()
        updatePolling()
    }

    private func refresh() async {
        recent = await store.recent(limit: 30)
        let all = await timers.list()
        breathTimers = all.filter { $0.label.localizedCaseInsensitiveContains("Breathing") }
    }

    public func logCheckin() async {
        _ = await store.log(mood: draftMood, note: draftNote.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        draftNote = ""
        statusMessage = "Check-in saved."
        await load()
    }

    public func startBreathingTimer(seconds: Int = 60) async {
        _ = await timers.cancel(id: nil, label: "Breathing")
        _ = await timers.schedule(seconds: max(1, seconds), label: "Breathing")
        statusMessage = "Breathing timer · \(seconds)s"
        await load()
    }

    private func updatePolling() {
        let shouldPoll = isScreenVisible || hasActiveBreathingTimer
        if !shouldPoll {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await self.refresh()
                if !self.isScreenVisible && !self.hasActiveBreathingTimer {
                    self.pollTask = nil
                    return
                }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
