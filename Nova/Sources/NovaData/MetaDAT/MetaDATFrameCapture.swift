import Foundation
import NovaCore
import NovaDomain

#if canImport(MWDATCamera) && os(iOS)
import UIKit
import MWDATCore
import MWDATCamera

/// Real Meta Wearables camera capture. Opens a low-FPS stream from the glasses
/// and delivers stills via `capturePhoto`, mapping the SDK's publisher model
/// onto Nova's async `FrameCapture` port. Self-manages a `DeviceSession`.
///
/// `MWDATCamera.Stream` is qualified throughout to avoid colliding with
/// `Foundation.Stream`.
public actor MetaDATFrameCapture: FrameCapture {
    private let policy: StreamBandwidthPolicy
    private var audioPriorityHold = false

    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var isStreaming = false
    private var listenerTokens: [Any] = []

    /// Kept alive across captures so `devicesStream` / `activeDeviceStream` stay
    /// in sync (Meta sample guidance — recreate-per-tap races `noEligibleDevice`).
    private var deviceSelector: AutoDeviceSelector?

    private var pendingPhoto: CheckedContinuation<Data, Error>?
    private var liveCont: AsyncStream<CapturedFrame>.Continuation?

    /// One-shot Meta AI recovery per cold open; reset after a successful stream
    /// or full camera release so later sessions can recover again.
    private var didAttemptDATAppUpdateRecovery = false
    private var didAttemptFirmwareUpdateRecovery = false

    public init(policy: StreamBandwidthPolicy = .default) {
        self.policy = policy
    }

    /// Call when conversational audio is under pressure — pauses live-look delivery.
    public func setAudioPriorityHold(_ hold: Bool) {
        audioPriorityHold = hold
    }

    public func captureStill() async throws -> CapturedFrame {
        try await ensureStreaming(fps: policy.liveLookFPS)
        guard let stream else { throw NovaError.vision("No active glasses stream") }

        let data: Data = try await withCheckedThrowingContinuation { cont in
            self.pendingPhoto = cont
            guard stream.capturePhoto(format: .jpeg) else {
                self.pendingPhoto = nil
                cont.resume(throwing: NovaError.vision("capturePhoto rejected (no device or bandwidth lease)"))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                await self?.timeoutPendingPhoto()
            }
        }

        let image = UIImage(data: data)
        NovaLog.vision.info("captured glasses still (\(data.count, privacy: .public) bytes)")
        return CapturedFrame(
            imageData: data,
            mimeType: "image/jpeg",
            width: Int(image?.size.width ?? 0),
            height: Int(image?.size.height ?? 0)
        )
    }

    public func startLiveLook(fps: Int) async throws -> AsyncStream<CapturedFrame> {
        let capped = min(max(fps, 1), policy.liveLookFPS)
        try await ensureStreaming(fps: capped)
        liveCont?.finish()
        let (out, cont) = AsyncStream<CapturedFrame>.makeStream()
        liveCont = cont
        return out
    }

    public func stopLiveLook() async {
        liveCont?.finish()
        liveCont = nil
    }

    public func prewarm() async {
        do {
            try await ensureStreaming(fps: policy.liveLookFPS)
        } catch {
            NovaLog.vision.info("camera prewarm skipped: \(String(describing: error), privacy: .public)")
        }
    }

    public func releaseCamera() async {
        liveCont?.finish()
        liveCont = nil
        pendingPhoto?.resume(throwing: NovaError.vision("Camera released"))
        pendingPhoto = nil
        listenerTokens.removeAll()
        // Dropping the strong references lets the SDK tear down the underlying
        // session/stream so the glasses capture indicator turns off.
        // Keep `deviceSelector` so the next open does not race discovery from zero.
        stream = nil
        deviceSession = nil
        isStreaming = false
        didAttemptDATAppUpdateRecovery = false
        didAttemptFirmwareUpdateRecovery = false
        NovaLog.vision.info("camera released")
    }

    // MARK: - Session / stream lifecycle

    private func ensureStreaming(fps: Int) async throws {
        if isStreaming, stream != nil { return }

        do {
            try await openStreamWithSoftRetries(fps: fps)
            didAttemptDATAppUpdateRecovery = false
            didAttemptFirmwareUpdateRecovery = false
            return
        } catch {
            // DAT-on-glasses bundle missing/stale — open Meta AI update once, then retry.
            if !didAttemptDATAppUpdateRecovery,
               MetaCameraOpenRetryPolicy.isDATAppUpdateRequired(error) {
                didAttemptDATAppUpdateRecovery = true
                NovaLog.vision.info("DAT app on glasses needs update — opening Meta AI recovery")
                await tearDownSessionOnly()
                let opened = await MetaDATConnectionRecovery.openDATGlassesAppUpdate()
                await MetaDATConnectionRecovery.waitAfterRecovery(openedMetaAI: opened)
                do {
                    try await openStreamWithSoftRetries(fps: fps)
                    didAttemptDATAppUpdateRecovery = false
                    didAttemptFirmwareUpdateRecovery = false
                    return
                } catch {
                    throw Self.mapCameraError(error)
                }
            }

            // Persistent noEligibleDevice often means firmware/compat — open update once.
            if !didAttemptFirmwareUpdateRecovery,
               MetaCameraOpenRetryPolicy.isFirmwareUpdateLikely(error) {
                didAttemptFirmwareUpdateRecovery = true
                NovaLog.vision.info("Glasses not eligible after soft retries — opening firmware update")
                await tearDownSessionOnly()
                let opened = await MetaDATConnectionRecovery.openFirmwareUpdate()
                await MetaDATConnectionRecovery.waitAfterRecovery(openedMetaAI: opened)
                do {
                    try await openStreamWithSoftRetries(fps: fps)
                    didAttemptDATAppUpdateRecovery = false
                    didAttemptFirmwareUpdateRecovery = false
                    return
                } catch {
                    throw Self.mapCameraError(error)
                }
            }

            throw Self.mapCameraError(error)
        }
    }

    private func openStreamWithSoftRetries(fps: Int) async throws {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try await openStream(fps: fps)
                return
            } catch {
                lastError = error
                // After Meta AI "Always Allow", BLE/link and session settle often lag
                // the permission callback — retry noEligibleDevice / stopped-before-start.
                // DAT update-required is handled by the outer recovery path, not sleep-retry.
                guard MetaCameraOpenRetryPolicy.isRetryable(error), attempt < 2 else {
                    throw error
                }
                NovaLog.vision.info(
                    "camera open retry \(attempt + 1) after: \(String(describing: error), privacy: .public)"
                )
                await tearDownSessionOnly()
                try await Task.sleep(for: .milliseconds(900))
            }
        }
        throw lastError ?? NovaError.vision("Glasses camera failed to open")
    }

    private func openStream(fps: Int) async throws {
        // Permission unlocks device visibility in some SDK builds; request first,
        // then wait for an *active* (connected + compatible) device before session.
        try await ensureCameraPermission()

        // Recreate the selector after permission so devicesStream is not stuck on a
        // pre-grant empty snapshot (Meta DAT 0.7+ community guidance).
        let selector = AutoDeviceSelector(wearables: Wearables.shared)
        deviceSelector = selector
        try await waitForActiveDevice(selector)

        let session = try Wearables.shared.createSession(deviceSelector: selector)
        // Meta DAT: create stateStream() before start() or the .started transition is missed.
        try await startDeviceSession(session)

        let config = StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: UInt(fps))
        guard let newStream = try session.addStream(config: config) else {
            throw NovaError.vision("Could not add camera stream (session not started)")
        }

        listenerTokens.append(newStream.statePublisher.listen { [weak self] (state: StreamState) in
            let streaming = (state == .streaming)
            Task { await self?.setStreaming(streaming) }
        })
        listenerTokens.append(newStream.photoDataPublisher.listen { [weak self] (photo: PhotoData) in
            let data = photo.data
            Task { await self?.deliverPhoto(data) }
        })
        listenerTokens.append(newStream.videoFramePublisher.listen { [weak self] (frame: VideoFrame) in
            guard let image = frame.makeUIImage(),
                  let jpeg = image.jpegData(compressionQuality: 0.6) else { return }
            let width = Int(image.size.width)
            let height = Int(image.size.height)
            Task { await self?.deliverLiveFrame(jpeg, width: width, height: height) }
        })

        deviceSession = session
        stream = newStream
        await newStream.start()
        try await waitForStreaming()
    }

    private func ensureCameraPermission() async throws {
        // Prefer status check so we do not re-open Meta AI when already granted.
        // Never map check failures to .denied — disconnected glasses make the SDK
        // throw / report unavailable even after Always Allow.
        var explicitStatus: PermissionStatus?
        for attempt in 0..<3 {
            do {
                let status = try await Wearables.shared.checkPermissionStatus(.camera)
                if status == .granted {
                    NovaLog.vision.info("glasses camera permission already granted")
                    return
                }
                NovaLog.vision.info(
                    "glasses camera permission status=\(String(describing: status), privacy: .public); will request via Meta AI"
                )
                explicitStatus = status
                break
            } catch {
                let detail = String(describing: error)
                NovaLog.vision.info(
                    "checkPermissionStatus failed (attempt \(attempt + 1)); not treating as denied: \(detail, privacy: .public)"
                )
                if attempt < 2 {
                    await waitBeforePermissionRecheck(attempt: attempt)
                    continue
                }
                if MetaCameraOpenRetryPolicy.isPermissionUnavailableMessage(detail) {
                    throw NovaError.vision(
                        "Glasses camera permission unavailable — wear the glasses, reconnect in Meta AI, then retry.\n\n\(Self.cameraChecklist)"
                    )
                }
                throw NovaError.vision(
                    "Could not read glasses camera permission status. Wear the glasses, open Meta AI, return to Nova, then retry.\n\n\(Self.cameraChecklist)"
                )
            }
        }

        guard explicitStatus != nil else {
            throw NovaError.vision(
                "Could not read glasses camera permission status. Wear the glasses, open Meta AI, return to Nova, then retry.\n\n\(Self.cameraChecklist)"
            )
        }

        NovaLog.vision.info("requesting glasses camera permission via Meta AI")
        let status = try await Wearables.shared.requestPermission(.camera)
        guard status == .granted else {
            throw NovaError.vision(
                "Camera permission was not granted in Meta AI. Open Meta AI → Apps → Nova and allow camera, then retry."
            )
        }
        // Wait for nova:// handleUrl to apply Always Allow, then BLE settle.
        await MetaWearablesURLGate.shared.waitUntilSettled(extraMilliseconds: 500)
    }

    private func waitBeforePermissionRecheck(attempt: Int) async {
        if let selector = deviceSelector {
            do {
                try await withTimeout(seconds: 3) {
                    for await device in selector.activeDeviceStream() {
                        if device != nil { return }
                    }
                }
            } catch {
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        } else {
            try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
        }
    }

    /// Meta requires a non-nil active device (connected + compatible) before
    /// `createSession` — otherwise you get `DeviceSessionError.noEligibleDevice`.
    private func waitForActiveDevice(
        _ selector: AutoDeviceSelector,
        timeout: Double = 20
    ) async throws {
        NovaLog.vision.info("waiting for active Meta glasses device…")
        try await withTimeout(seconds: timeout) {
            for await device in selector.activeDeviceStream() {
                if device != nil {
                    NovaLog.vision.info("active Meta glasses device ready")
                    return
                }
            }
            throw NovaError.vision("Glasses disconnected while waiting for an active device")
        }
    }

    private func tearDownSessionOnly() {
        listenerTokens.removeAll()
        stream = nil
        deviceSession = nil
        isStreaming = false
    }

    private func setStreaming(_ value: Bool) { isStreaming = value }

    private func deliverPhoto(_ data: Data) {
        guard let cont = pendingPhoto else { return }
        pendingPhoto = nil
        cont.resume(returning: data)
    }

    private func timeoutPendingPhoto() {
        guard let cont = pendingPhoto else { return }
        pendingPhoto = nil
        cont.resume(throwing: NovaError.vision("Photo capture timed out"))
    }

    private func deliverLiveFrame(_ jpeg: Data, width: Int, height: Int) {
        guard !(audioPriorityHold && policy.preferAudio) else { return }
        liveCont?.yield(CapturedFrame(imageData: jpeg, mimeType: "image/jpeg", width: width, height: height))
    }

    /// Subscribe to `stateStream` (and errors) **before** `start()` — Meta DAT docs:
    /// creating the stream after start misses the `.started` transition and a later
    /// `.stopped` looks like "closed before it could open."
    private func startDeviceSession(_ session: DeviceSession) async throws {
        try await withTimeout(seconds: 15) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await state in session.stateStream() {
                        if state == .started { return }
                        if state == .stopped {
                            throw NovaError.vision("Glasses session stopped before it started")
                        }
                    }
                    throw NovaError.vision("Glasses session state stream ended before start")
                }
                group.addTask {
                    for await error in session.errorStream() {
                        throw error
                    }
                }
                // Let the for-await subscriptions attach before start().
                await Task.yield()
                try await Task.sleep(for: .milliseconds(25))
                try session.start()
                try await group.next()
                group.cancelAll()
            }
        }
    }

    private func waitForStreaming(timeout: Double = 15) async throws {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(timeout) {
            if isStreaming { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NovaError.vision("Glasses stream did not start in time")
    }

    private func withTimeout(seconds: Double, _ operation: @Sendable @escaping () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw NovaError.vision("Glasses operation timed out — wear the glasses, keep Meta AI open, then retry.")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Maps opaque SDK permission/session failures into actionable UI copy.
    /// Raw values like 4419815456 are not documented enum cases — describe them,
    /// do not invent named mappings from the integer alone.
    private static func mapCameraError(_ error: Error) -> Error {
        if let nova = error as? NovaError, case .vision(_) = nova {
            return error
        }

        if let permission = error as? PermissionError {
            let tip: String
            switch permission {
            case .noDevice:
                tip = "No Meta glasses found. Pair them in Meta AI, wear them, then retry."
            case .noDeviceWithConnection:
                tip = "Glasses are paired but not connected. Unfold/wear them near the phone, open Meta AI, then retry."
            case .metaAINotInstalled:
                tip = "Install or update the Meta AI app, then retry."
            case .requestInProgress:
                tip = "A Meta AI permission prompt is already open — finish it, return to Nova, then retry."
            case .requestTimeout:
                tip = "Camera permission timed out in Meta AI. Tap What’s this? again and choose Always Allow."
            case .connectionError:
                tip = "Lost the link to the glasses while asking for camera access. Reconnect in Meta AI and retry."
            case .internalError:
                tip = "Meta AI reported an internal camera-permission error. Force-quit Meta AI and Nova, then retry."
            @unknown default:
                tip = "Camera permission failed (\(String(describing: permission)))."
            }
            return NovaError.vision("\(tip)\n\n\(Self.cameraChecklist)")
        }

        if let sessionError = error as? DeviceSessionError {
            let tip: String
            switch sessionError {
            case .datAppOnTheGlassesUpdateRequired:
                tip = "The DAT app on your glasses needs an update. Nova opens Meta AI automatically for Install/Update — finish that prompt, return here, then retry What’s this? (or tap Fix glasses connection)."
            case .noEligibleDevice:
                tip = "Glasses not ready for camera yet (connected + compatible required). Wear them, unlock the phone, wait a few seconds after Always Allow, then retry. If this persists, Nova will open a firmware update in Meta AI."
            default:
                tip = "Glasses session failed: \(String(describing: sessionError))."
            }
            return NovaError.vision("\(tip)\n\n\(Self.cameraChecklist)")
        }

        return NovaError.vision(
            "Glasses camera failed: \(String(describing: error))\n\n\(Self.cameraChecklist)"
        )
    }

    private static let cameraChecklist = """
    Checklist:
    1) Glasses on, unfolded, paired in Meta AI
    2) Nova shows Connected under Glasses (Fix glasses connection / Re-link if needed)
    3) In Meta AI, Always Allow camera for Nova; Install/Update DAT on glasses if prompted
    4) Only one Developer Mode app registered at a time
    5) Retry What’s this? a few seconds after returning from Meta AI
    """
}

#else

/// Fallback camera capture used when the Meta Wearables SDK isn't linked (e.g.
/// non-iOS builds). Emits a placeholder frame so the vision path stays runnable.
public actor MetaDATFrameCapture: FrameCapture {
    private let policy: StreamBandwidthPolicy
    private var liveTask: Task<Void, Never>?
    private var liveCont: AsyncStream<CapturedFrame>.Continuation?
    private var audioPriorityHold = false

    public init(policy: StreamBandwidthPolicy = .default) {
        self.policy = policy
    }

    public func setAudioPriorityHold(_ hold: Bool) {
        audioPriorityHold = hold
        if hold {
            Task { await stopLiveLook() }
        }
    }

    public func captureStill() async throws -> CapturedFrame {
        let placeholder = Data([0xFF, 0xD8, 0xFF, 0xD9])
        NovaLog.vision.info("captureStill (adapter stub — Meta SDK not linked)")
        return CapturedFrame(imageData: placeholder, width: 1, height: 1)
    }

    public func startLiveLook(fps: Int) async throws -> AsyncStream<CapturedFrame> {
        let capped = min(max(fps, 1), policy.liveLookFPS)
        await stopLiveLook()
        var cont: AsyncStream<CapturedFrame>.Continuation!
        let outStream = AsyncStream<CapturedFrame> { cont = $0 }
        liveCont = cont
        liveTask = Task {
            while !Task.isCancelled {
                if await self.audioPriorityHold && self.policy.preferAudio {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                if let frame = try? await self.captureStill() {
                    cont.yield(frame)
                }
                let delayMs = max(1, 1000 / capped)
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
            cont.finish()
        }
        return outStream
    }

    public func stopLiveLook() async {
        liveTask?.cancel()
        liveTask = nil
        liveCont?.finish()
        liveCont = nil
    }

    public func prewarm() async {}

    public func releaseCamera() async {
        await stopLiveLook()
    }
}

#endif
