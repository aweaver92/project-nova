import Foundation
import NovaDomain

#if canImport(Network)
import Network
#endif

/// Resolves Nova Bridge's `_nova-bridge._tcp` Bonjour service on the current LAN.
///
/// Bonjour follows DHCP address changes automatically, so a router restart does
/// not leave the app pinned to yesterday's IP address. The resolved endpoint is
/// still validated against `/health` before it is accepted.
public actor BonjourBridgeDiscovery: BridgeDiscovering {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 2.5) {
        self.session = session
        self.timeout = max(0.25, timeout)
    }

    public func discoverBridgeURL() async -> String? {
        #if canImport(Network)
        guard let candidate = await BonjourEndpointResolver.resolve(timeout: timeout) else {
            return nil
        }
        return await BridgeDiscoveryValidator.validate(baseURL: candidate, session: session)
        #else
        return nil
        #endif
    }
}

enum BridgeDiscoveryValidator {
    static func validate(baseURL: String, session: URLSession) async -> String? {
        guard let url = URL(string: "\(baseURL)/health") else { return nil }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 1.5
        )
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
}

#if canImport(Network)
/// One-shot `NWBrowser` wrapper. `NWConnection` resolves the Bonjour SRV target
/// and exposes its concrete host/port without sending application data.
private final class BonjourEndpointResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private var browser: NWBrowser?
    private var connections: [NWConnection] = []
    private var finished = false

    static func resolve(timeout: TimeInterval) async -> String? {
        let resolver = BonjourEndpointResolver()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resolver.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            resolver.finish(nil)
        }
    }

    private func start(
        timeout: TimeInterval,
        continuation: CheckedContinuation<String?, Never>
    ) {
        let queue = DispatchQueue(label: "nova.bridge.bonjour")
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_nova-bridge._tcp", domain: nil),
            using: parameters
        )

        lock.lock()
        self.continuation = continuation
        self.browser = browser
        lock.unlock()

        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish(nil) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                self?.resolve(result.endpoint, on: queue)
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(nil)
        }
        browser.start(queue: queue)
    }

    private func resolve(_ endpoint: NWEndpoint, on queue: DispatchQueue) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        lock.lock()
        guard !finished else {
            lock.unlock()
            connection.cancel()
            return
        }
        connections.append(connection)
        lock.unlock()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state,
                  let remote = connection?.currentPath?.remoteEndpoint,
                  case let .hostPort(host, port) = remote
            else { return }

            let rawHost = String(describing: host)
            let urlHost = rawHost.contains(":")
                ? "[\(rawHost.replacingOccurrences(of: "%", with: "%25"))]"
                : rawHost
            self?.finish("http://\(urlHost):\(port.rawValue)")
        }
        connection.start(queue: queue)
    }

    private func finish(_ result: String?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let browser = self.browser
        self.browser = nil
        let connections = self.connections
        self.connections = []
        lock.unlock()

        browser?.cancel()
        connections.forEach { $0.cancel() }
        continuation?.resume(returning: result)
    }
}
#endif
