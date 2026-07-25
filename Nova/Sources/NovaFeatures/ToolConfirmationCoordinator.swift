import Foundation
import Observation

/// Presents destructive tool / skill confirmations via a single pending prompt.
@MainActor
@Observable
public final class ToolConfirmationCoordinator {
    public struct Prompt: Identifiable {
        public let id: UUID
        public let title: String
        public let detail: String
        fileprivate let resume: (Bool) -> Void

        public init(id: UUID = UUID(), title: String, detail: String, resume: @escaping (Bool) -> Void) {
            self.id = id
            self.title = title
            self.detail = detail
            self.resume = resume
        }
    }

    public private(set) var prompt: Prompt?

    public init() {}

    /// Ask the user to allow a destructive action. Returns `false` if superseded.
    public func confirm(title: String, detail: String) async -> Bool {
        if let existing = prompt {
            existing.resume(false)
            prompt = nil
        }
        return await withCheckedContinuation { continuation in
            prompt = Prompt(title: title, detail: detail) { [weak self] allowed in
                self?.prompt = nil
                continuation.resume(returning: allowed)
            }
        }
    }

    public func respond(_ allowed: Bool) {
        guard let prompt else { return }
        self.prompt = nil
        prompt.resume(allowed)
    }
}
