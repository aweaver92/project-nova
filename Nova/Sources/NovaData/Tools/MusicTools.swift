import Foundation
import NovaDomain

/// Opens a URL / deep link (spotify:, music://, https:, maps:, etc.).
public struct OpenURLTool: Tool {
    public let name = "open_url"
    public let description = "Open a deep link or URL on the phone (spotify:, music://, https://, maps:, etc.)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"url":{"type":"string","description":"Full URL or deep link to open."}},"required":["url"],"additionalProperties":false}
    """
    public typealias URLOpener = @Sendable (URL) async -> Bool
    private let openURL: URLOpener?

    public init(openURL: URLOpener?) {
        self.openURL = openURL
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let url: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let url = URL(string: args.url) else {
            return #"{"ok":false,"error":"invalid_url"}"#
        }
        guard let openURL else {
            return #"{"ok":false,"error":"open_url_unavailable"}"#
        }
        let ok = await openURL(url)
        return #"{"ok":\#(ok),"url":"\#(Self.escape(args.url))"}"#
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Play music via Spotify/Apple Music deep link, optionally preferring a Home
/// Assistant media_player when configured.
public struct PlayMusicTool: Tool {
    public let name = "play_music"
    public let description = "Play music: opens Spotify or Apple Music with a search/query or URI. If Home Assistant is configured and media_player_entity is set, prefers HA media_player.play_media / media_play."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"query":{"type":"string","description":"Song, artist, playlist, or album to search/play."},"uri":{"type":"string","description":"Optional full deep link (spotify:... or https://music.apple.com/...)."},"service":{"type":"string","description":"Preferred service: 'spotify' (default) or 'apple_music'."},"media_player_entity":{"type":"string","description":"Optional HA media_player entity_id to play on."}},"additionalProperties":false}
    """
    public typealias URLOpener = @Sendable (URL) async -> Bool
    private let openURL: URLOpener?
    private let haBaseURL: URL?
    private let haToken: String?

    public init(openURL: URLOpener?, haBaseURL: URL? = nil, haToken: String? = nil) {
        self.openURL = openURL
        self.haBaseURL = haBaseURL
        self.haToken = haToken
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let query: String?
            let uri: String?
            let service: String?
            let media_player_entity: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))

        if let entity = args.media_player_entity, let haBaseURL, let haToken {
            let ok = await playOnHomeAssistant(
                entityId: entity,
                query: args.query,
                uri: args.uri,
                baseURL: haBaseURL,
                token: haToken
            )
            if ok {
                return #"{"ok":true,"via":"home_assistant","entity":"\#(Self.escape(entity))"}"#
            }
        }

        guard let url = Self.resolveURL(query: args.query, uri: args.uri, service: args.service) else {
            return #"{"ok":false,"error":"missing_query_or_uri"}"#
        }
        guard let openURL else {
            return #"{"ok":false,"error":"open_url_unavailable","hint":"\#(Self.escape(url.absoluteString))"}"#
        }
        let ok = await openURL(url)
        return #"{"ok":\#(ok),"via":"deeplink","url":"\#(Self.escape(url.absoluteString))"}"#
    }

    static func resolveURL(query: String?, uri: String?, service: String?) -> URL? {
        if let uri, let url = URL(string: uri), !uri.isEmpty { return url }
        guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let svc = (service ?? "spotify").lowercased()
        if svc.contains("apple") {
            return URL(string: "music://music.apple.com/search?term=\(encoded)")
                ?? URL(string: "https://music.apple.com/search?term=\(encoded)")
        }
        return URL(string: "spotify:search:\(encoded)")
            ?? URL(string: "https://open.spotify.com/search/\(encoded)")
    }

    private func playOnHomeAssistant(
        entityId: String,
        query: String?,
        uri: String?,
        baseURL: URL,
        token: String
    ) async -> Bool {
        // Prefer play_media when we have a content id; otherwise media_play.
        if let content = uri ?? query {
            var request = URLRequest(url: baseURL.appending(path: "api/services/media_player/play_media"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "entity_id": entityId,
                "media_content_id": content,
                "media_content_type": "music"
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                return true
            }
        }
        var request = URLRequest(url: baseURL.appending(path: "api/services/media_player/media_play"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["entity_id": entityId])
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
