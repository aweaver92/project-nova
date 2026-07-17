import Foundation
import NovaCore
import NovaDomain

/// Folds a workspace's not-yet-summarized turns into its durable digest once
/// enough have accrued. Runs opportunistically (e.g. in the background at session
/// start) so it never blocks the live conversation.
public actor MemoryCompactor: MemoryCompacting {
    private let memory: any ConversationMemory
    private let digestStore: any MemoryDigestStoring
    private let summarizer: any MemorySummarizing
    private let threshold: Int
    private let fetchLimit: Int

    /// - Parameter threshold: minimum new turns before a compaction runs.
    public init(
        memory: any ConversationMemory,
        digestStore: any MemoryDigestStoring,
        summarizer: any MemorySummarizing,
        threshold: Int = 20,
        fetchLimit: Int = 500
    ) {
        self.memory = memory
        self.digestStore = digestStore
        self.summarizer = summarizer
        self.threshold = threshold
        self.fetchLimit = fetchLimit
    }

    public func compactIfNeeded(workspaceId: UUID?) async {
        let coveredThrough = await digestStore.coveredThrough(workspaceId: workspaceId)
        let all = await memory.recent(workspaceId: workspaceId, limit: fetchLimit)
        let fresh = all.filter { turn in
            guard let coveredThrough else { return true }
            return turn.at > coveredThrough
        }
        guard fresh.count >= threshold, let newest = fresh.map(\.at).max() else { return }

        let previous = await digestStore.digest(workspaceId: workspaceId)
        let updated = await summarizer.summarize(previousDigest: previous, turns: fresh)
        // Only persist if the summarizer actually produced something new.
        guard !updated.isEmpty, updated != previous else { return }
        await digestStore.setDigest(updated, coveredThrough: newest, workspaceId: workspaceId)
        NovaLog.session.info("Compacted \(fresh.count) turns into workspace digest")
    }
}
