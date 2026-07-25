import Foundation
import NovaCore
import NovaDomain

public actor FileShoppingStore: ShoppingListStoring {
    private let url: URL
    private var items: [ShoppingListItem]

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.items = Self.load(from: resolved)
    }

    public func all() -> [ShoppingListItem] {
        items.sorted { lhs, rhs in
            if lhs.checked != rhs.checked { return !lhs.checked && rhs.checked }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    @discardableResult
    public func upsert(_ item: ShoppingListItem) -> ShoppingListItem {
        var updated = item
        updated.updatedAt = Date()
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = updated
        } else if let idx = items.firstIndex(where: {
            !$0.checked && $0.name.localizedCaseInsensitiveCompare(item.name) == .orderedSame
        }) {
            let prior = items[idx]
            updated = ShoppingListItem(
                id: prior.id,
                name: item.name,
                quantity: item.quantity ?? prior.quantity,
                fromRecipeId: item.fromRecipeId ?? prior.fromRecipeId,
                checked: item.checked,
                category: item.category ?? prior.category,
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

    public func clearChecked() -> Int {
        let before = items.count
        items.removeAll { $0.checked }
        let removed = before - items.count
        if removed > 0 { persist() }
        return removed
    }

    public func summary() -> String {
        let open = all().filter { !$0.checked }
        guard !open.isEmpty else { return "" }
        let list = open.map { item -> String in
            if let q = item.quantity, !q.isEmpty { return "\(item.name) (\(q))" }
            return item.name
        }.joined(separator: "; ")
        return "Shopping list (\(open.count) unchecked): \(list)."
    }

    private func persist() {
        do {
            try JSONEncoder().encode(items).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Shopping persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [ShoppingListItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ShoppingListItem].self, from: data)) ?? []
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-shopping.json")
    }
}
