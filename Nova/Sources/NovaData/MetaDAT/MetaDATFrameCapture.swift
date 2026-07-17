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

    private var pendingPhoto: CheckedContinuation<Data, Error>?
    private var liveCont: AsyncStream<CapturedFrame>.Continuation?

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
        stream = nil
        deviceSession = nil
        isStreaming = false
        NovaLog.vision.info("camera released")
    }

    // MARK: - Session / stream lifecycle

    private func ensureStreaming(fps: Int) async throws {
        if isStreaming, stream != nil { return }

        // The app must be registered with Meta AI; camera access is then granted
        // per-device through the Meta AI companion app.
        let status = try await Wearables.shared.requestPermission(.camera)
        guard status == .granted else {
            throw NovaError.vision("Camera permission not granted on the glasses")
        }

        let selector = AutoDeviceSelector(wearables: Wearables.shared)
        let session = try Wearables.shared.createSession(deviceSelector: selector)
        try session.start()
        try await waitForSessionStarted(session)

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

    private func waitForSessionStarted(_ session: DeviceSession) async throws {
        try await withTimeout(seconds: 15) {
            for await state in session.stateStream() {
                if state == .started { return }
                if state == .stopped { throw NovaError.vision("Glasses session stopped before it started") }
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
                throw NovaError.vision("Glasses operation timed out")
            }
            try await group.next()
            group.cancelAll()
        }
    }
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
