import Foundation
import NovaCore

#if canImport(MWDATCore) && os(iOS)
import MWDATCore
#endif

/// Serializes Meta AI deep-link callbacks (`Wearables.handleUrl`) so camera
/// session open waits until Always-Allow is applied before `createSession`.
public actor MetaWearablesURLGate {
    public static let shared = MetaWearablesURLGate()

    private var inFlight: Task<Void, Error>?
    private var generation = 0

    /// Process a Meta AI callback URL and record completion for waiters.
    public func handle(_ url: URL) async throws {
        #if canImport(MWDATCore) && os(iOS)
        generation += 1
        let myGeneration = generation
        let task = Task {
            _ = try await Wearables.shared.handleUrl(url)
        }
        inFlight = task
        do {
            try await task.value
            if generation == myGeneration { inFlight = nil }
            NovaLog.session.info("Wearables.handleUrl completed")
        } catch {
            if generation == myGeneration { inFlight = nil }
            NovaLog.session.error(
                "Wearables.handleUrl failed: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
        #else
        _ = url
        #endif
    }

    /// Await any in-flight `handleUrl`, then a short settle for BLE/permission apply.
    public func waitUntilSettled(extraMilliseconds: Int = 500) async {
        if let inFlight {
            _ = try? await inFlight.value
        }
        let delay = max(0, extraMilliseconds)
        if delay > 0 {
            try? await Task.sleep(for: .milliseconds(delay))
        }
    }
}
