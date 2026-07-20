import Foundation

public enum NovaError: Error, Sendable, Equatable {
    case notConfigured(String)
    case audioSession(String)
    case wearable(String)
    case aiProvider(String)
    case credentials(String)
    case vision(String)
    case tool(String)
    case cancelled
}

extension NovaError: LocalizedError {
    /// Surfaces the associated tip instead of Foundation's opaque
    /// `NovaCore.NovaError error N` bridging (e.g. vision == 5).
    public var errorDescription: String? {
        switch self {
        case .notConfigured(let message),
             .audioSession(let message),
             .wearable(let message),
             .aiProvider(let message),
             .credentials(let message),
             .vision(let message),
             .tool(let message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }
}

public struct EphemeralCredential: Sendable, Equatable, Codable {
    public let token: String
    public let expiresAt: Date

    public init(token: String, expiresAt: Date) {
        self.token = token
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-30)
    }
}
