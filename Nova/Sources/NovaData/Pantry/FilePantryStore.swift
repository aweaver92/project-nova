import Foundation
import NovaCore
import NovaDomain

public actor FilePantryStore: PantryStoring {
    private let url: URL
    private var items: [PantryItem]

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.items = Self.load(from: resolved)
    }

    public func all() -> [PantryItem] {
        items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func upsert(_ item: PantryItem) -> PantryItem {
        var updated = item
        updated.updatedAt = Date()
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = updated
        } else if let idx = items.firstIndex(where: {
            $0.name.localizedCaseInsensitiveCompare(item.name) == .orderedSame
        }) {
            let prior = items[idx]
            updated = PantryItem(
                id: prior.id,
                name: item.name,
                quantity: item.quantity ?? prior.quantity,
                notes: item.notes ?? prior.notes,
                category: item.category == .other && prior.category != .other ? prior.category : item.category,
                location: item.location == .pantry && prior.location != .pantry ? prior.location : item.location,
                stockLevel: item.stockLevel,
                expiresAt: item.expiresAt ?? prior.expiresAt,
                updatedAt: Date()
            )
            items[idx] = updated
        } else {
            items.append(updated)
        }
        persist()
        return updated
    }

    public func delete(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    public func clear() {
        items = []
        persist()
    }

    public func summary() -> String {
        let all = all()
        guard !all.isEmpty else { return "" }
        let list = all.map { item -> String in
            var parts = [item.name]
            if let q = item.quantity, !q.isEmpty { parts.append("(\(q))") }
            if item.stockLevel != .ok { parts.append("[\(item.stockLevel.rawValue)]") }
            if let exp = item.expiresAt {
                let df = DateFormatter()
                df.dateStyle = .short
                parts.append("exp \(df.string(from: exp))")
            }
            parts.append("@\(item.location.rawValue)")
            return parts.joined(separator: " ")
        }.joined(separator: "; ")
        let low = all.filter { $0.stockLevel == .low || $0.stockLevel == .out }.map(\.name)
        var text = "Pantry / fridge inventory: \(list)."
        if !low.isEmpty {
            text += " Low/out: \(low.joined(separator: ", "))."
        }
        return text
    }

    private func persist() {
        do {
            try JSONEncoder().encode(items).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Pantry persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [PantryItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PantryItem].self, from: data)) ?? []
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-pantry.json")
    }
}
