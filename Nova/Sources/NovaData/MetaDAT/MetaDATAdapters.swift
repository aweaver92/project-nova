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
    public let state: AsyncStream<WearableSessionState>
    public let registration: AsyncStream<NovaDomain.RegistrationState>

    private var current: WearableSessionState = .idle
    private var reg: NovaDomain.RegistrationState = .unknown
    private let useMock: Bool

    #if canImport(MWDATCore) && os(iOS)
    private var regObservation: Task<Void, Never>?
    #endif

    public init(useMock: Bool = true) {
        self.useMock = useMock
        var sCont: AsyncStream<WearableSessionState>.Continuation!
        var rCont: AsyncStream<NovaDomain.RegistrationState>.Continuation!
        state = AsyncStream { sCont = $0 }
        registration = AsyncStream { rCont = $0 }
        stateCont = sCont
        regCont = rCont
    }

    public func register() async throws {
        #if canImport(MWDATCore) && os(iOS)
        if !useMock {
            setState(.registering)
            observeRegistration()
            // Opens the Meta AI companion app; the result arrives asynchronously
            // via registrationStateStream() after Meta AI calls back into handleUrl.
            _ = try await Wearables.shared.startRegistration()
            NovaLog.session.info("DAT registration started (awaiting Meta AI)")
            return
        }
        #endif

        setReg(.unregistered)
        setState(.registering)
        try await Task.sleep(for: .milliseconds(300))
        setReg(.registered)
        setState(.ready)
        NovaLog.session.info("DAT mock registration complete")
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
    #endif
}
