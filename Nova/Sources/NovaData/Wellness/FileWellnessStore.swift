import Foundation
import NovaCore
import NovaDomain

public actor FileWellnessStore: WellnessStoring {
    private let url: URL
    private var checkins: [WellnessCheckin]

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.checkins = Self.load(from: resolved)
    }

    @discardableResult
    public func log(mood: Int, note: String?) -> WellnessCheckin {
        let entry = WellnessCheckin(mood: mood, note: note)
        checkins.append(entry)
        persist()
        return entry
    }

    public func recent(limit: Int) -> [WellnessCheckin] {
        Array(checkins.sorted { $0.at > $1.at }.prefix(max(0, limit)))
    }

    public func summary(limit: Int) -> String {
        let recent = recent(limit: limit)
        guard !recent.isEmpty else { return "" }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var lines = ["Recent wellness check-ins:"]
        for c in recent {
            let mood = "mood \(c.mood)/5"
            let note = (c.note?.isEmpty == false) ? " — \(c.note!)" : ""
            lines.append("- \(df.string(from: c.at)): \(mood)\(note)")
        }
        return lines.joined(separator: "\n")
    }

    private func persist() {
        do {
            try JSONEncoder().encode(checkins).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Wellness persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [WellnessCheckin] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([WellnessCheckin].self, from: data)) ?? []
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-wellness.json")
    }
}
