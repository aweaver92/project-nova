import Foundation
import NovaDomain

/// Voice → UI navigation hook. RootView binds `onOpen` so tools can jump to the
/// Agents tab and a specialist screen without importing SwiftUI in NovaData.
@MainActor
@Observable
public final class AppNavigationBridge {
    /// routeKey matches `AgentsPendingRoute.rawValue`; kitchenSection is optional.
    public var onOpen: ((String, String?) -> Void)?

    public init() {}

    public func open(routeKey: String, kitchenSection: String?) -> Bool {
        guard let onOpen else { return false }
        onOpen(routeKey, kitchenSection)
        return true
    }
}
