import Foundation
import NovaCore
import NovaDomain

public actor FileTaskStore: AgentTaskStoring {
    private let url: URL
    private let imagesDir: URL
    private var tasks: [AgentTask]

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.imagesDir = resolved.deletingLastPathComponent()
            .appendingPathComponent("nova-task-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        self.tasks = Self.load(from: resolved)
    }

    public func all() -> [AgentTask] {
        tasks.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func open(limit: Int) -> [AgentTask] {
        Array(
            tasks
                .filter(\.status.isOpen)
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(max(0, limit))
        )
    }

    public func forAgent(name: String?, status: AgentTaskStatus?, limit: Int) -> [AgentTask] {
        var filtered = tasks
        if let name, !name.isEmpty {
            let needle = name.lowercased()
            filtered = filtered.filter { $0.agentName.lowercased() == needle }
        }
        if let status {
            filtered = filtered.filter { $0.status == status }
        }
        return Array(filtered.sorted { $0.updatedAt > $1.updatedAt }.prefix(max(0, limit)))
    }

    @discardableResult
    public func upsert(_ task: AgentTask) -> AgentTask {
        var next = task
        next.updatedAt = Date()
        if let idx = tasks.firstIndex(where: { $0.id == next.id }) {
            next.createdAt = tasks[idx].createdAt
            // Drop image files removed from the task.
            let removed = Set(tasks[idx].imageFileNames).subtracting(next.imageFileNames)
            for name in removed { removeImageFile(name) }
            tasks[idx] = next
        } else {
            tasks.append(next)
        }
        persist()
        return next
    }

    @discardableResult
    public func updateStatus(id: UUID, status: AgentTaskStatus) -> AgentTask? {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        tasks[idx].status = status
        tasks[idx].updatedAt = Date()
        persist()
        return tasks[idx]
    }

    public func delete(id: UUID) {
        if let task = tasks.first(where: { $0.id == id }) {
            for name in task.imageFileNames {
                removeImageFile(name)
            }
        }
        tasks.removeAll { $0.id == id }
        persist()
    }

    public func summary(limit: Int) -> String {
        let open = open(limit: limit)
        guard !open.isEmpty else { return "No open tasks." }
        var lines = ["Open tasks (\(open.count)):"]
        for task in open {
            var line = "- [\(task.status.rawValue)] \(task.agentName): \(task.title)"
            if let detail = task.detail, !detail.isEmpty {
                line += " — \(detail)"
            }
            if !task.imageFileNames.isEmpty {
                line += " · \(task.imageFileNames.count) image\(task.imageFileNames.count == 1 ? "" : "s")"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    public func saveTaskImage(_ jpegData: Data) -> String {
        let name = "nova-task-\(UUID().uuidString).jpg"
        let dest = imagesDir.appendingPathComponent(name)
        try? jpegData.write(to: dest, options: .atomic)
        return name
    }

    public func taskImageURL(fileName: String) -> URL? {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") , !trimmed.contains("\\") else { return nil }
        let url = imagesDir.appendingPathComponent(trimmed)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func removeTaskImage(fileName: String) {
        removeImageFile(fileName)
    }

    private func removeImageFile(_ fileName: String) {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(trimmed))
    }

    private func persist() {
        do {
            try JSONEncoder().encode(tasks).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Task persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [AgentTask] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([AgentTask].self, from: data)) ?? []
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-tasks.json")
    }
}
