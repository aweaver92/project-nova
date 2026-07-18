import Foundation
import NovaCore
import NovaDomain
#if canImport(MWDATCore) && os(iOS)
import MWDATCore
#endif

/// Meta Wearables DAT session adapter.
///
/// - `useMock: true` drives a faithful in-memory state machine (used by tests and
///   Simulator runs without glasses).
/// - `useMock: false` (device, SDK linked) registers the app with Meta AI via
///   `Wearables.shared` and mirrors the SDK's registration state.
///
/// Our `RegistrationState` is qualified as `NovaDomain.RegistrationState`
/// throughout because `MWDATCore` also declares a `RegistrationState`.
public actor MetaDATWearableSession: WearableSession {
    private var stateCont: AsyncStream<WearableSessionState>.Continuation?
    private var regCont: AsyncStream<NovaDomain.RegistrationState>.Continuation?
    private var diagCont: AsyncStream<String>.Continuation?
    public let state: AsyncStream<WearableSessionState>
    public let registration: AsyncStream<NovaDomain.RegistrationState>
    public let diagnostics: AsyncStream<String>

    private var current: WearableSessionState = .idle
    private var reg: NovaDomain.RegistrationState = .unknown
    private var transitions: [String] = []
    private let useMock: Bool

    private static let diagTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    #if canImport(MWDATCore) && os(iOS)
    private var regObservation: Task<Void, Never>?
    #endif

    public init(useMock: Bool = true) {
        self.useMock = useMock
        var sCont: AsyncStream<WearableSessionState>.Continuation!
        var rCont: AsyncStream<NovaDomain.RegistrationState>.Continuation!
        var dCont: AsyncStream<String>.Continuation!
        state = AsyncStream { sCont = $0 }
        registration = AsyncStream { rCont = $0 }
        diagnostics = AsyncStream { dCont = $0 }
        stateCont = sCont
        regCont = rCont
        diagCont = dCont
    }

    /// Record a diagnostics line (timestamped) and publish the latest snapshot of
    /// recent transitions so the UI can show exactly where registration fails.
    private func diag(_ message: String) {
        let stamp = Self.diagTimeFormatter.string(from: Date())
        transitions.append("[\(stamp)] \(message)")
        if transitions.count > 12 { transitions.removeFirst(transitions.count - 12) }
        NovaLog.session.info("DAT: \(message, privacy: .public)")
        diagCont?.yield(transitions.joined(separator: "\n"))
    }

    /// True when DAT registration succeeded (or mock mode).
    public func isRegistered() -> Bool {
        useMock || reg == .registered
    }

    public func register() async throws {
        #if canImport(MWDATCore) && os(iOS)
        if !useMock {
            setState(.registering)
            diag("Register tapped — Developer Mode (MetaAppID=0). Opening Meta AI…")
            observeRegistration()
            // Opens the Meta AI companion app; the result arrives asynchronously
            // via registrationStateStream() after Meta AI calls back into handleUrl.
            do {
                _ = try await Wearables.shared.startRegistration()
                diag("startRegistration() returned; awaiting Meta AI callback")
            } catch {
                // Meta AI only allows one Developer Mode app at a time. If Nova is
                // already linked, `startRegistration` throws instead of succeeding —
                // treat that as connected so Connect is not stuck on an error.
                if Self.isAlreadyRegistered(error) {
                    diag("Already registered with Meta AI — treating as connected")
                    setReg(.registered)
                    setState(.ready)
                    NovaLog.session.info("DAT already registered; synced as connected")
                    return
                }
                let mapped = Self.mapRegistrationError(error)
                diag("startRegistration() threw: \(mapped)")
                setReg(.failed)
                setState(.failed)
                throw NovaError.wearable(mapped)
            }
            NovaLog.session.info("DAT registration started (awaiting Meta AI)")
            return
        }
        #endif

        setReg(.unregistered)
        setState(.registering)
        diag("[mock] registering")
        try await Task.sleep(for: .milliseconds(300))
        setReg(.registered)
        setState(.ready)
        diag("[mock] registered")
        NovaLog.session.info("DAT mock registration complete")
    }

    /// Start mirroring the SDK registration stream so a prior Meta AI link is
    /// reflected in the UI without requiring another Register tap.
    public func syncRegistrationFromSDK() async {
        #if canImport(MWDATCore) && os(iOS)
        guard !useMock else { return }
        observeRegistration()
        diag("Observing Meta AI registration state")
        #endif
    }

    public func start() async throws {
        guard reg == .registered || useMock else {
            throw NovaError.wearable("Not registered with Meta AI")
        }
        // The camera capability creates its own DeviceSession on demand
        // (see MetaDATFrameCapture), so this only tracks logical session state.
        setState(.active)
        NovaLog.session.info("DAT session active")
    }

    public func pause() async {
        guard current == .active else { return }
        setState(.paused)
    }

    public func resume() async {
        guard current == .paused else { return }
        setState(.active)
    }

    public func stop() async {
        setState(.ending)
        setState(.idle)
    }

    private func setState(_ s: WearableSessionState) {
        current = s
        stateCont?.yield(s)
    }

    private func setReg(_ r: NovaDomain.RegistrationState) {
        reg = r
        regCont?.yield(r)
    }

    #if canImport(MWDATCore) && os(iOS)
    private func observeRegistration() {
        guard regObservation == nil else { return }
        regObservation = Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                await self?.applyRegistration(state)
            }
        }
    }

    private func applyRegistration(_ sdkState: MWDATCore.RegistrationState) {
        diag("SDK registration → \(String(describing: sdkState))")
        switch sdkState {
        case .registered:
            setReg(.registered)
            setState(.ready)
            NovaLog.session.info("DAT registration complete")
        case .registering:
            setReg(.unregistered)
            setState(.registering)
        default:
            // .available / .unavailable — app known to Meta AI but not yet approved.
            setReg(.unregistered)
        }
    }

    /// Maps SDK `RegistrationError` (and opaque failures) into actionable copy.
    private static func mapRegistrationError(_ error: Error) -> String {
        let checklist = """
        Developer Mode checklist:
        1) Meta AI installed; glasses paired & connected
        2) In Meta AI App Info, tap version 7×, toggle Developer Mode OFF→ON, force-quit Meta AI
        3) Retry Register from Nova (callback scheme nova://)
        4) Only one third-party Developer Mode app can stay registered
        """
        if let reg = error as? RegistrationError {
            let tip: String
            switch reg {
            case .alreadyRegistered:
                tip = "Already registered — check Meta AI → App connections, or unregister and retry."
            case .configurationInvalid:
                tip = "DAT config invalid — confirm Wearables.configure() and MetaAppID=0 (Developer Mode)."
            case .metaAINotInstalled:
                tip = "Install or update the Meta AI app, then retry."
            case .networkUnavailable:
                tip = "Network unavailable — reconnect Wi‑Fi/cellular and retry."
            case .timeout:
                tip = "Registration timed out — keep Nova and Meta AI in the foreground and retry."
            case .unknown:
                tip = "Unknown registration error from Meta AI."
            @unknown default:
                tip = "Unrecognized RegistrationError (\(String(describing: reg)))."
            }
            return "\(tip)\n\(String(describing: reg))\n\n\(checklist)"
        }
        return "Registration failed: \(String(describing: error))\n\n\(checklist)"
    }

    private static func isAlreadyRegistered(_ error: Error) -> Bool {
        if let reg = error as? RegistrationError, case .alreadyRegistered = reg {
            return true
        }
        let text = String(describing: error).lowercased()
        return text.contains("alreadyregistered") || text.contains("already registered")
    }
    #endif
}
