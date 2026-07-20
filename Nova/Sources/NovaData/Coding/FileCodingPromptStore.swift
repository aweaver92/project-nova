import Foundation
import NovaCore
import NovaDomain

/// File-backed per-repo Coding templates, history, and path pins.
public actor FileCodingPromptStore: CodingPromptStoring {
    private struct Bag: Codable {
        var repos: [String: CodingRepoPromptState]
    }

    private let url: URL
    private var bag: Bag

    private static let maxHistory = 50
    private static let maxTemplates = 20
    private static let maxPins = 3

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.bag = Self.load(from: resolved)
    }

    public func state(repoId: String) async -> CodingRepoPromptState {
        let key = normalizeRepoId(repoId)
        if let existing = bag.repos[key] { return existing }
        let fresh = CodingRepoPromptState(repoId: key)
        bag.repos[key] = fresh
        return fresh
    }

    public func setPinnedPaths(_ paths: [CodingContextPin], repoId: String) async {
        let key = normalizeRepoId(repoId)
        var state = await state(repoId: key)
        var seen = Set<String>()
        var next: [CodingContextPin] = []
        for pin in paths {
            let path = pin.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !seen.contains(path), next.count < Self.maxPins else { continue }
            seen.insert(path)
            next.append(CodingContextPin(path: path, kind: pin.kind))
        }
        state.pinnedPaths = next
        bag.repos[key] = state
        persist()
    }

    public func upsertTemplate(_ template: CodingPromptTemplate, repoId: String) async {
        let key = normalizeRepoId(repoId)
        var state = await state(repoId: key)
        var updated = template
        updated.updatedAt = Date()
        if let idx = state.templates.firstIndex(where: { $0.id == template.id }) {
            state.templates[idx] = updated
        } else {
            state.templates.insert(updated, at: 0)
        }
        if state.templates.count > Self.maxTemplates {
            state.templates = Array(state.templates.prefix(Self.maxTemplates))
        }
        bag.repos[key] = state
        persist()
    }

    public func deleteTemplate(id: UUID, repoId: String) async {
        let key = normalizeRepoId(repoId)
        var state = await state(repoId: key)
        state.templates.removeAll { $0.id == id }
        bag.repos[key] = state
        persist()
    }

    public func appendHistory(_ entry: CodingPromptHistoryEntry, repoId: String) async {
        let key = normalizeRepoId(repoId)
        var state = await state(repoId: key)
        state.history.insert(entry, at: 0)
        if state.history.count > Self.maxHistory {
            state.history = Array(state.history.prefix(Self.maxHistory))
        }
        bag.repos[key] = state
        persist()
    }

    public func updateHistory(_ entry: CodingPromptHistoryEntry, repoId: String) async {
        let key = normalizeRepoId(repoId)
        var state = await state(repoId: key)
        if let idx = state.history.firstIndex(where: { $0.id == entry.id }) {
            state.history[idx] = entry
        } else {
            state.history.insert(entry, at: 0)
            if state.history.count > Self.maxHistory {
                state.history = Array(state.history.prefix(Self.maxHistory))
            }
        }
        bag.repos[key] = state
        persist()
    }

    public func clearHistory(repoId: String) async {
        let key = normalizeRepoId(repoId)
        var state = await state(repoId: key)
        state.history = []
        bag.repos[key] = state
        persist()
    }

    private func normalizeRepoId(_ repoId: String) -> String {
        repoId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persist() {
        do {
            try JSONEncoder().encode(bag).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Coding prompt persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> Bag {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Bag.self, from: data)
        else {
            return Bag(repos: [:])
        }
        return decoded
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-coding-prompts.json")
    }
}
