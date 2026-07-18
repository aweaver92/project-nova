import Foundation
import NovaDomain
import Observation

@MainActor
@Observable
public final class SageWellnessViewModel {
    public private(set) var recent: [WellnessCheckin] = []
    public private(set) var statusMessage: String = ""
    public var draftMood: Int = 3
    public var draftNote: String = ""

    private let store: any WellnessStoring
    private let timers: any TimerScheduling

    public init(store: any WellnessStoring, timers: any TimerScheduling) {
        self.store = store
        self.timers = timers
    }

    public var averageMoodLabel: String {
        guard !recent.isEmpty else { return "No check-ins yet" }
        let avg = Double(recent.map(\.mood).reduce(0, +)) / Double(recent.count)
        return String(format: "Avg mood %.1f / 5", avg)
    }

    public func load() async {
        recent = await store.recent(limit: 30)
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
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
