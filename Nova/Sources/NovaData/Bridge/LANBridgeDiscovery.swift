import Darwin
import Foundation
import NovaDomain

/// Probes the current Wi-Fi /24 for Nova Bridge's unauthenticated health endpoint.
///
/// Nova Bridge normally listens on port 8787. A validated service response is
/// required, so another HTTP server on that port cannot be selected accidentally.
public actor LANBridgeDiscovery: BridgeDiscovering {
    private let session: URLSession
    private let port: Int
    private let batchSize: Int

    public init(
        session: URLSession = .shared,
        port: Int = 8787,
        batchSize: Int = 32
    ) {
        self.session = session
        self.port = port
        self.batchSize = max(1, batchSize)
    }

    public func discoverBridgeURL() async -> String? {
        guard let prefix = Self.wifiIPv4Prefix() else { return nil }
        let hosts = Array(1...254)

        // Bound concurrency so scanning cannot overwhelm the phone or access point.
        for start in stride(from: 0, to: hosts.count, by: batchSize) {
            if Task.isCancelled { return nil }
            let end = min(start + batchSize, hosts.count)
            let batch = hosts[start..<end]

            if let found = await withTaskGroup(of: String?.self, returning: String?.self) { group in
                for host in batch {
                    let baseURL = "http://\(prefix).\(host):\(port)"
                    group.addTask { [session] in
                        await Self.validate(baseURL: baseURL, session: session)
                    }
                }
                for await result in group {
                    if let result {
                        group.cancelAll()
                        return result
                    }
                }
                return nil
            } {
                return found
            }
        }
        return nil
    }

    private static func validate(baseURL: String, session: URLSession) async -> String? {
        guard let url = URL(string: "\(baseURL)/health") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 0.8)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ok"] as? Bool == true,
                  json["service"] as? String == "nova-bridge"
            else { return nil }
            return baseURL
        } catch {
            return nil
        }
    }

    /// `en0` is Wi-Fi on iOS. A /24 is overwhelmingly the common home-network
    /// layout and keeps discovery quick and predictable.
    private static func wifiIPv4Prefix() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) == "en0"
            else { continue }

            var address = interface.ifa_addr.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                &address,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let parts = String(cString: hostname).split(separator: ".")
            guard parts.count == 4 else { continue }
            return parts.prefix(3).joined(separator: ".")
        }
        return nil
    }
}
