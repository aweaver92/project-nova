import Foundation
import NovaCore
import NovaDomain

public struct WeatherTool: Tool {
    public let name = "weather"
    public let description = "Get a short weather summary for a city."
    public let requiresConfirmation = false
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let city: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        // Placeholder: integrate Open-Meteo or WeatherKit in production.
        return #"{"city":"\#(args.city)","summary":"Weather lookup stub — wire WeatherKit/Open-Meteo"}"#
    }
}

public struct RemindersTool: Tool {
    public let name = "reminders"
    public let description = "Create a local reminder (requires confirmation)."
    public let requiresConfirmation = true

    public init() {}

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let title: String
            let dueISO8601: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        // Production: EventKit EKReminder
        NovaLog.tools.info("reminder queued: \(args.title, privacy: .public)")
        return #"{"ok":true,"title":"\#(args.title)"}"#
    }
}

public struct HomeAssistantTool: Tool {
    public let name = "home_assistant"
    public let description = "Call a Home Assistant service (requires confirmation)."
    public let requiresConfirmation = true
    public let baseURL: URL?
    public let token: String?

    public init(baseURL: URL? = nil, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let domain: String
            let service: String
            let entityId: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let baseURL, let token else {
            throw NovaError.tool("Home Assistant not configured")
        }
        var request = URLRequest(url: baseURL.appending(path: "api/services/\(args.domain)/\(args.service)"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [:]
        if let entityId = args.entityId { body["entity_id"] = entityId }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NovaError.tool("Home Assistant call failed")
        }
        return #"{"ok":true}"#
    }
}
