import Foundation
import NovaCore
import NovaDomain

/// File-backed workspaces + active selection. Seeds a "Default" workspace on
/// first launch so there is always an active context.
public actor FileWorkspaceStore: WorkspaceStoring {
    private struct Persisted: Codable {
        var workspaces: [Workspace]
        var activeId: UUID?
    }

    private let url: URL
    private var workspaces: [Workspace]
    private var activeId: UUID?

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        let loaded = Self.load(from: resolved)
        if loaded.workspaces.isEmpty {
            let def = Workspace(name: "Default", contextNotes: "")
            self.workspaces = [def]
            self.activeId = def.id
            Self.persist(Persisted(workspaces: [def], activeId: def.id), to: resolved)
        } else {
            self.workspaces = loaded.workspaces
            self.activeId = loaded.activeId ?? loaded.workspaces.first?.id
        }
    }

    public func all() -> [Workspace] {
        workspaces.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func create(name: String, contextNotes: String) -> Workspace {
        let ws = Workspace(name: name.trimmingCharacters(in: .whitespacesAndNewlines), contextNotes: contextNotes)
        workspaces.append(ws)
        persist()
        return ws
    }

    public func update(_ workspace: Workspace) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        var updated = workspace
        updated.updatedAt = Date()
        workspaces[idx] = updated
        persist()
    }

    public func delete(id: UUID) {
        workspaces.removeAll { $0.id == id }
        // Never leave the app without an active workspace.
        if workspaces.isEmpty {
            let def = Workspace(name: "Default")
            workspaces = [def]
            activeId = def.id
        } else if activeId == id {
            activeId = workspaces.first?.id
        }
        persist()
    }

    public func active() -> Workspace? {
        workspaces.first { $0.id == activeId } ?? workspaces.first
    }

    public func setActive(id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        activeId = id
        persist()
    }

    private func persist() {
        Self.persist(Persisted(workspaces: workspaces, activeId: activeId), to: url)
    }

    private static func persist(_ value: Persisted, to url: URL) {
        do {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Workspace persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> Persisted {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return Persisted(workspaces: [], activeId: nil)
        }
        return decoded
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-workspaces.json")
    }
}
