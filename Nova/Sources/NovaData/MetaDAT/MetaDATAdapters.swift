import Foundation
import NovaCore
import NovaDomain

/// Meta Wearables DAT session adapter.
/// Wire `MWDATCore` types here when the official SPM package is linked in Xcode.
/// Until then this provides a faithful state machine + mock registration for hello-world.
public actor MetaDATWearableSession: WearableSession {
    private var stateCont: AsyncStream<WearableSessionState>.Continuation?
    private var regCont: AsyncStream<RegistrationState>.Continuation?
    public let state: AsyncStream<WearableSessionState>
    public let registration: AsyncStream<RegistrationState>

    private var current: WearableSessionState = .idle
    private var reg: RegistrationState = .unknown
    private let useMock: Bool

    public init(useMock: Bool = true) {
        self.useMock = useMock
        var sCont: AsyncStream<WearableSessionState>.Continuation!
        var rCont: AsyncStream<RegistrationState>.Continuation!
        state = AsyncStream { sCont = $0 }
        registration = AsyncStream { rCont = $0 }
        stateCont = sCont
        regCont = rCont
    }

    public func register() async throws {
        setReg(.unregistered)
        setState(.registering)
        // Production: Wearables.register() → Meta AI deeplink confirmation.
        if useMock {
            try await Task.sleep(for: .milliseconds(300))
            setReg(.registered)
            setState(.ready)
            NovaLog.session.info("DAT mock registration complete")
            return
        }
        throw NovaError.notConfigured("Link Meta Wearables DAT (mwdat-core) and replace MetaDATWearableSession.register()")
    }

    public func start() async throws {
        guard reg == .registered || useMock else {
            throw NovaError.wearable("Not registered")
        }
        // Production: create DeviceSession via Wearables.startSession()
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

    private func setReg(_ r: RegistrationState) {
        reg = r
        regCont?.yield(r)
    }
}
