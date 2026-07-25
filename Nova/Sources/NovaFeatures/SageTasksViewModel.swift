import Foundation
import NovaDomain
import Observation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
public final class SageTasksViewModel {
    public private(set) var openTasks: [AgentTask] = []
    public private(set) var recentDone: [AgentTask] = []
    public private(set) var statusMessage: String = ""
    public var draftTitle: String = ""
    public var draftAgent: String = "Nova"
    public var draftDetail: String = ""
    /// Pending JPEG bytes for the Quick-add form (not yet persisted).
    public private(set) var draftImageData: [Data] = []

    /// True while Tasks is on-screen (drives polling for voice-written tasks).
    public private(set) var isScreenVisible = false

    public let agentChoices = ["Nova", "Claude", "Max", "Remy", "Scholar", "Sage"]
    public static let maxImagesPerTask = 4

    private let store: any AgentTaskStoring
    private var pollTask: Task<Void, Never>?

    public init(store: any AgentTaskStoring) {
        self.store = store
    }

    public var openCount: Int { openTasks.count }

    public var groupedOpen: [(agent: String, tasks: [AgentTask])] {
        let order = agentChoices
        let grouped = Dictionary(grouping: openTasks) { $0.agentName }
        let keys = grouped.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max
            let ib = order.firstIndex(of: b) ?? Int.max
            if ia != ib { return ia < ib }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return keys.map { ($0, grouped[$0] ?? []) }
    }

    public var hasResumeSignal: Bool { !openTasks.isEmpty }

    public var resumeSubtitle: String {
        if openTasks.isEmpty {
            return "Track pickups across agents"
        }
        let suggested = openTasks.filter { $0.status == .suggested }.count
        if suggested > 0 {
            return "\(openCount) open · \(suggested) suggested"
        }
        return "\(openCount) open task\(openCount == 1 ? "" : "s")"
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
        openTasks = await store.open(limit: 40)
        recentDone = await store.forAgent(name: nil, status: .done, limit: 8)
    }

    public func addDraftImage(_ jpegData: Data) {
        guard draftImageData.count < Self.maxImagesPerTask else {
            statusMessage = "Max \(Self.maxImagesPerTask) images per task."
            return
        }
        guard !jpegData.isEmpty else { return }
        draftImageData.append(jpegData)
    }

    public func removeDraftImage(at index: Int) {
        guard draftImageData.indices.contains(index) else { return }
        draftImageData.remove(at: index)
    }

    public func clearDraftImages() {
        draftImageData = []
    }

    public func addDraftTask() async {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            statusMessage = "Add a title first."
            return
        }
        let detail = draftDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        var fileNames: [String] = []
        for data in draftImageData.prefix(Self.maxImagesPerTask) {
            fileNames.append(await store.saveTaskImage(data))
        }
        _ = await store.upsert(AgentTask(
            title: title,
            detail: detail.isEmpty ? nil : detail,
            agentName: draftAgent,
            status: .incomplete,
            source: "manual",
            imageFileNames: fileNames
        ))
        draftTitle = ""
        draftDetail = ""
        draftImageData = []
        statusMessage = fileNames.isEmpty ? "Task added." : "Task added with \(fileNames.count) image\(fileNames.count == 1 ? "" : "s")."
        await load()
    }

    public func attachImages(to task: AgentTask, jpegData: [Data]) async {
        guard !jpegData.isEmpty else { return }
        var next = task
        var names = next.imageFileNames
        for data in jpegData {
            guard names.count < Self.maxImagesPerTask else { break }
            names.append(await store.saveTaskImage(data))
        }
        next.imageFileNames = names
        _ = await store.upsert(next)
        statusMessage = "Attached image\(jpegData.count == 1 ? "" : "s") to \(task.title)."
        await load()
    }

    public func removeImage(from task: AgentTask, fileName: String) async {
        var next = task
        next.imageFileNames.removeAll { $0 == fileName }
        await store.removeTaskImage(fileName: fileName)
        _ = await store.upsert(next)
        statusMessage = "Removed image from \(task.title)."
        await load()
    }

    public func imageURL(for fileName: String) async -> URL? {
        await store.taskImageURL(fileName: fileName)
    }

    public func setStatus(_ task: AgentTask, status: AgentTaskStatus) async {
        _ = await store.updateStatus(id: task.id, status: status)
        statusMessage = "\(task.title) → \(status.displayName)"
        await load()
    }

    public func cycleStatus(_ task: AgentTask) async {
        let next: AgentTaskStatus
        switch task.status {
        case .suggested: next = .inProgress
        case .inProgress: next = .incomplete
        case .incomplete: next = .done
        case .done, .cancelled: next = .incomplete
        }
        await setStatus(task, status: next)
    }

    public func markDone(_ task: AgentTask) async {
        await setStatus(task, status: .done)
    }

    public func delete(_ task: AgentTask) async {
        await store.delete(id: task.id)
        statusMessage = "Removed \(task.title)."
        await load()
    }

    private func updatePolling() {
        pollTask?.cancel()
        pollTask = nil
        guard isScreenVisible else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
}

#if canImport(UIKit)
extension SageTasksViewModel {
    /// Compress a UIImage picker result to JPEG suitable for task attachment.
    public static func jpegAttachment(from data: Data, maxDimension: CGFloat = 1600) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.82)
    }
}
#endif
