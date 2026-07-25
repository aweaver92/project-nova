import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Short iOS background execution window for bridge start / poll / SSE ticks.
/// Kept in NovaCore so Features (Coding recover) and Data (SSE) can both renew
/// while the phone is locked.
public enum BackgroundTask {
    public struct Handle: @unchecked Sendable {
        #if canImport(UIKit)
        let rawValue: Int
        var id: UIBackgroundTaskIdentifier { UIBackgroundTaskIdentifier(rawValue: rawValue) }
        #else
        public let rawValue: Int
        #endif

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
    }

    @MainActor
    public static func begin(name: String) -> Handle {
        #if canImport(UIKit)
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(id)
        }
        return Handle(rawValue: id.rawValue)
        #else
        return Handle(rawValue: -1)
        #endif
    }

    /// End the previous window and open a fresh one so long polls stay alive.
    @MainActor
    public static func renew(_ handle: Handle, name: String) -> Handle {
        end(handle)
        return begin(name: name)
    }

    @MainActor
    public static func end(_ handle: Handle) {
        #if canImport(UIKit)
        let id = handle.id
        if id != .invalid {
            UIApplication.shared.endBackgroundTask(id)
        }
        #endif
    }
}

/// Mutable handle box so SSE / poll loops can renew from a heartbeat Task.
public final class BackgroundTaskBox: @unchecked Sendable {
    public var handle: BackgroundTask.Handle
    public init(_ handle: BackgroundTask.Handle) { self.handle = handle }
}
