import Foundation
import NovaCore
import NovaDomain

/// Live weather via Open-Meteo (free, no API key): geocode the city, then fetch
/// current conditions.
public struct WeatherTool: Tool {
    public let name = "weather"
    public let description = "Get current weather for a city (temperature, conditions, wind)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"city":{"type":"string","description":"City name, e.g. 'Austin' or 'Paris, France'"}},"required":["city"],"additionalProperties":false}
    """
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let city: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))

        guard let geo = try await geocode(args.city) else {
            return #"{"ok":false,"error":"city_not_found","city":"\#(args.city)"}"#
        }
        let (tempF, code, windMph) = try await currentConditions(lat: geo.lat, lon: geo.lon)
        let summary = Self.describe(code)
        return """
        {"ok":true,"city":"\(geo.name)","temperature_f":\(Int(tempF.rounded())),"conditions":"\(summary)","wind_mph":\(Int(windMph.rounded()))}
        """
    }

    private struct Geo { let name: String; let lat: Double; let lon: Double }

    private func geocode(_ city: String) async throws -> Geo? {
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [
            .init(name: "name", value: city),
            .init(name: "count", value: "1")
        ]
        struct Response: Decodable {
            struct Result: Decodable { let name: String; let latitude: Double; let longitude: Double; let admin1: String?; let country: String? }
            let results: [Result]?
        }
        let (data, _) = try await session.data(from: comps.url!)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let first = decoded.results?.first else { return nil }
        let label = [first.name, first.admin1, first.country].compactMap { $0 }.first ?? first.name
        return Geo(name: label, lat: first.latitude, lon: first.longitude)
    }

    private func currentConditions(lat: Double, lon: Double) async throws -> (Double, Int, Double) {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,weather_code,wind_speed_10m"),
            .init(name: "temperature_unit", value: "fahrenheit"),
            .init(name: "wind_speed_unit", value: "mph")
        ]
        struct Response: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let weather_code: Int
                let wind_speed_10m: Double
            }
            let current: Current
        }
        let (data, _) = try await session.data(from: comps.url!)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return (decoded.current.temperature_2m, decoded.current.weather_code, decoded.current.wind_speed_10m)
    }

    /// WMO weather interpretation codes → short text.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1, 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55, 56, 57: return "drizzle"
        case 61, 63, 65, 66, 67: return "rain"
        case 71, 73, 75, 77: return "snow"
        case 80, 81, 82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95, 96, 99: return "thunderstorm"
        default: return "unknown"
        }
    }
}

/// Calls a Home Assistant service (e.g. turn lights on/off). Configured via a base
/// URL + long-lived token; unconfigured instances report a clear error.
public struct HomeAssistantTool: Tool {
    public let name = "home_assistant"
    public let description = "Control smart-home devices via Home Assistant (e.g. turn lights/switches on or off)."
    public let requiresConfirmation = true
    public let parametersJSON = """
    {"type":"object","properties":{"domain":{"type":"string","description":"HA domain, e.g. 'light', 'switch', 'climate'"},"service":{"type":"string","description":"Service to call, e.g. 'turn_on', 'turn_off', 'toggle'"},"entityId":{"type":"string","description":"Target entity_id, e.g. 'light.office'"}},"required":["domain","service"],"additionalProperties":false}
    """
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
        return #"{"ok":true,"domain":"\#(args.domain)","service":"\#(args.service)"}"#
    }
}

/// Reads the current state (and friendly name/attributes) of a Home Assistant
/// entity — e.g. "is the garage door open?", "what's the thermostat set to?".
public struct HomeAssistantStateTool: Tool {
    public let name = "home_assistant_state"
    public let description = "Query the current state of a Home Assistant entity (e.g. a sensor, light, lock, or thermostat) by entity_id. Use to answer questions about the smart home."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"entityId":{"type":"string","description":"Target entity_id, e.g. 'lock.front_door' or 'sensor.living_room_temperature'"}},"required":["entityId"],"additionalProperties":false}
    """
    public let baseURL: URL?
    public let token: String?
    private let session: URLSession

    public init(baseURL: URL? = nil, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let entityId: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let baseURL, let token else {
            throw NovaError.tool("Home Assistant not configured")
        }
        var request = URLRequest(url: baseURL.appending(path: "api/states/\(args.entityId)"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NovaError.tool("Home Assistant call failed")
        }
        if http.statusCode == 404 {
            return #"{"ok":false,"error":"entity_not_found","entityId":"\#(args.entityId)"}"#
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NovaError.tool("Home Assistant call failed")
        }
        return Self.summarize(data: data, entityId: args.entityId)
    }

    /// Reduces HA's verbose state payload to state + friendly name + unit.
    static func summarize(data: Data, entityId: String) -> String {
        struct State: Decodable {
            let state: String
            struct Attributes: Decodable {
                let friendly_name: String?
                let unit_of_measurement: String?
            }
            let attributes: Attributes?
        }
        guard let decoded = try? JSONDecoder().decode(State.self, from: data) else {
            return #"{"ok":false,"error":"bad_response","entityId":"\#(entityId)"}"#
        }
        var payload: [String: Any] = ["ok": true, "entityId": entityId, "state": decoded.state]
        if let name = decoded.attributes?.friendly_name { payload["name"] = name }
        if let unit = decoded.attributes?.unit_of_measurement { payload["unit"] = unit }
        let out = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) }
        return out ?? #"{"ok":false,"error":"encode_failed"}"#
    }
}
