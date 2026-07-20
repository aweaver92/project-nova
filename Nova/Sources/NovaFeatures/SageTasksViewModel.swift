import Foundation
import NovaDomain
import Observation

@MainActor
@Observable
public final class SageTasksViewModel {
    public private(set) var openTasks: [AgentTask] = []
    public private(set) var recentDone: [AgentTask] = []
    public private(set) var statusMessage: String = ""
    public var draftTitle: String = ""
    public var draftAgent: String = "Nova"
    public var draftDetail: String = ""

    /// True while Tasks is on-screen (drives polling for voice-written tasks).
    public private(set) var isScreenVisible = false

    public let agentChoices = ["Nova", "Claude", "Max", "Remy", "Scholar", "Sage"]

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

    public func addDraftTask() async {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            statusMessage = "Add a title first."
            return
        }
        let detail = draftDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await store.upsert(AgentTask(
            title: title,
            detail: detail.isEmpty ? nil : detail,
            agentName: draftAgent,
            status: .incomplete,
            source: "manual"
        ))
        draftTitle = ""
        draftDetail = ""
        statusMessage = "Task added."
        await load()
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
        case .done, .cancelled: next = .suggested
        }
        await setStatus(task, status: next)
    }

    public func markDone(_ task: AgentTask) async {
        await setStatus(task, status: .done)
    }

    public func delete(_ task: AgentTask) async {
        await store.delete(id: task.id)
        statusMessage = "Removed."
        await load()
    }

    private func updatePolling() {
        if !isScreenVisible {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                await self.refresh()
                if !self.isScreenVisible {
                    self.pollTask = nil
                    return
                }
            }
        }
    }
}
