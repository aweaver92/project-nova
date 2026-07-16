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
