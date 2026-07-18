import AVFoundation
import Foundation
import NovaCore
import NovaDomain

#if os(iOS)
/// Captures mono PCM from the active HFP route (glasses mic when preferred).
public final class HFPGlassesAudioIngress: AudioIngress, MicRouteControlling, @unchecked Sendable {
    /// ~1s of newest audio at ~20 ms/chunk; older chunks are dropped under backpressure.
    public static let chunkBufferCapacity = 48

    private let coordinator: AudioSessionCoordinator
    private let metrics: (any LatencyMetricsRecorder)?
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    /// Guards flags / stream identity. Engine mutations go through `engineQueue`.
    private let lock = NSLock()
    /// Serializes all `AVAudioEngine` start/stop/tap work. Core Audio is not safe
    /// for concurrent mutation from recovery Tasks + agent-switch teardown.
    private let engineQueue = DispatchQueue(label: "nova.hfp.ingress.engine")
    private var observers: [NSObjectProtocol] = []
    private var running = false
    private var recoveryGeneration = 0
    private var lastPeak: Float = 0
    private var flippedOnce = false

    // Recreated on every `start()` so the mic feed can be torn down and brought
    // back within a single app run (e.g. switching agents reconnects the stream).
    public private(set) var chunks: AsyncStream<AudioChunk>

    public init(coordinator: AudioSessionCoordinator, metrics: (any LatencyMetricsRecorder)? = nil) {
        self.coordinator = coordinator
        self.metrics = metrics
        var cont: AsyncStream<AudioChunk>.Continuation?
        self.chunks = AsyncStream(bufferingPolicy: .bufferingNewest(Self.chunkBufferCapacity)) { cont = $0 }
        self.continuation = cont
    }

    public func peakLevel() async -> Float {
        lock.lock()
        defer { lock.unlock() }
        return lastPeak
    }

    public func inputRouteLabel() async -> String {
        AudioSessionCoordinator.currentInputDescription()
    }

    public func flipPreferredInput() async {
        lock.lock()
        if flippedOnce {
            lock.unlock()
            return
        }
        flippedOnce = true
        lock.unlock()
        let next = !coordinator.preferBuiltInMicEnabled()
        coordinator.setPreferBuiltInMic(next)
        NovaLog.audio.warning(
            "Silent mic failover → preferBuiltIn=\(next, privacy: .public); restarting capture"
        )
        recover()
    }

    public func start() async throws {
        lock.lock()
        running = true
        flippedOnce = false
        lastPeak = 0
        // Each Listen session starts HFP-first (early working default). Silence
        // diagnostics may flip once to the built-in mic during the session.
        coordinator.setPreferBuiltInMic(false)
        // A fresh stream per engage. `stop()` finishes the previous continuation,
        // and yielding into a finished continuation silently drops audio — which
        // previously killed transcription for good after the first teardown
        // (e.g. the first agent switch). Rebuild it before the tap emits.
        let previous = continuation
        var cont: AsyncStream<AudioChunk>.Continuation?
        chunks = AsyncStream(bufferingPolicy: .bufferingNewest(Self.chunkBufferCapacity)) { cont = $0 }
        continuation = cont
        lock.unlock()
        previous?.finish()

        try await coordinator.activateConversationalHFP()
        // Input format can report 0 Hz for a beat after route activation; retry
        // briefly instead of starting a tap that would mis-label PCM to the cloud.
        var started = false
        var lastError: Error?
        for attempt in 0..<6 {
            do {
                try await mutateEngine {
                    try self.installTapAndStartEngine()
                }
                started = true
                break
            } catch {
                lastError = error
                NovaLog.audio.warning(
                    "HFP tap not ready (attempt \(attempt + 1)): \(String(describing: error), privacy: .public)"
                )
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        guard started else {
            throw lastError ?? NovaError.audioSession("HFP tap failed to start")
        }
        registerObservers()
        NovaLog.audio.info("HFP ingress started (\(AudioSessionCoordinator.currentInputDescription(), privacy: .public))")
    }

    private func installTapAndStartEngine() throws {
        let input = engine.inputNode
        // Enable the Voice-Processing I/O unit (AEC + noise suppression + AGC).
        // Must be toggled while the engine is stopped; guard against redundant
        // re-enables on route-change/interruption recovery. Early working builds
        // used VP on the HFP path.
        if !input.isVoiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(true)
                NovaLog.audio.info("Voice processing (AEC/NS/AGC) enabled")
            } catch {
                NovaLog.audio.warning("Voice processing unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        input.removeTap(onBus: 0)
        let format = input.inputFormat(forBus: 0)
        // Reject the transient 0 Hz formats Core Audio can report during route
        // flips — emitting those mislabeled as 8/24 kHz produces "ws ok" appends
        // that cloud VAD never treats as speech.
        guard format.sampleRate >= 8_000, format.channelCount >= 1 else {
            throw NovaError.audioSession(
                "Input format not ready (\(format.sampleRate) Hz, \(format.channelCount) ch)"
            )
        }
        // Capture at OpenAI's native 24 kHz so uplink skips the 8→24 resampler.
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ) else {
            throw NovaError.audioSession("Failed to build 24 kHz PCM16 tap format")
        }
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw NovaError.audioSession(
                "No converter \(format.sampleRate)Hz → 24kHz PCM16"
            )
        }

        input.installTap(onBus: 0, bufferSize: 2_880, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let capturedAt = ContinuousClock.Instant.now
            let ratio = target.sampleRate / format.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return }
            var error: NSError?
            var consumed = false
            converter.convert(to: outBuffer, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil {
                self.emit(Self.int16Data(from: outBuffer), sampleRate: 24_000, capturedAt: capturedAt)
            }
        }

        engine.prepare()
        try engine.start()
    }

    /// Run engine mutations on the serial queue (bridging sync Core Audio APIs).
    private func mutateEngine(_ body: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            engineQueue.async {
                do {
                    try body()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func mutateEngineSync(_ body: () -> Void) {
        engineQueue.sync(execute: body)
    }

    // MARK: - Resilience: interruptions & route changes

    private func registerObservers() {
        // Always clear first so a duplicate `start()` cannot leak NotificationCenter
        // tokens and multiply recovery work after agent switches.
        unregisterObservers()
        let center = NotificationCenter.default
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
        let routeChange = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            self?.handleRouteChange(note)
        }
        lock.lock()
        observers = [interruption, routeChange]
        lock.unlock()
    }

    private func unregisterObservers() {
        lock.lock()
        let toRemove = observers
        observers = []
        lock.unlock()
        toRemove.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            NovaLog.audio.info("Audio interruption began; pausing engine")
            mutateEngineSync { self.engine.stop() }
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            // Prefer `.shouldResume`, but still attempt recovery while we believe
            // the session is active — missing the flag previously left capture muted.
            if !options.contains(.shouldResume) {
                NovaLog.audio.info("Audio interruption ended without shouldResume; attempting recovery anyway")
            } else {
                NovaLog.audio.info("Audio interruption ended; resuming engine")
            }
            recover()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .categoryChange, .override:
            NovaLog.audio.info("Audio route changed (reason \(raw)); re-selecting HFP input")
            recover()
        default:
            break
        }
    }

    /// Reactivate the HFP session and restart the capture tap after an
    /// interruption or route change. Coalesces overlapping recoveries.
    private func recover() {
        lock.lock()
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        let alive = running
        lock.unlock()
        guard alive else { return }
        Task { [weak self] in
            guard let self else { return }
            // Debounce rapid route flaps.
            try? await Task.sleep(for: .milliseconds(80))
            self.lock.lock()
            let stillCurrent = self.recoveryGeneration == generation && self.running
            self.lock.unlock()
            guard stillCurrent else { return }
            do {
                try await self.coordinator.activateConversationalHFP()
                self.lock.lock()
                let stillAlive = self.recoveryGeneration == generation && self.running
                self.lock.unlock()
                guard stillAlive else { return }
                try await self.mutateEngine {
                    try self.installTapAndStartEngine()
                }
            } catch {
                NovaLog.audio.error("HFP recovery failed: \(String(describing: error), privacy: .public)")
                self.metrics?.increment(.sessionFailures)
            }
        }
    }

    public func stop() async {
        lock.lock()
        running = false
        recoveryGeneration &+= 1
        let sink = continuation
        continuation = nil
        lock.unlock()
        unregisterObservers()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            engineQueue.async {
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
                cont.resume()
            }
        }
        await coordinator.deactivate()
        sink?.finish()
    }

    private func emit(_ data: Data, sampleRate: Int, capturedAt: ContinuousClock.Instant) {
        guard !data.isEmpty, sampleRate > 0 else { return }
        let peak = Self.peakLevel(of: data)
        lock.lock()
        let sink = continuation
        let alive = running
        // Smooth the meter so UI isn't flicker-y, but keep peaks responsive.
        lastPeak = max(peak, lastPeak * 0.85)
        lock.unlock()
        guard alive, let sink else { return }
        // bufferingNewest drops oldest under backpressure; yield's discarded
        // value isn't exposed, so queue lag is observed via t_mic_queue_wait.
        sink.yield(AudioChunk(pcm: data, sampleRate: sampleRate, capturedAt: capturedAt))
    }

    /// Peak absolute sample as 0...1 for the mic meter.
    private static func peakLevel(of pcm16: Data) -> Float {
        guard pcm16.count >= 2 else { return 0 }
        var peak: Int16 = 0
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for s in samples {
                let a = s == Int16.min ? Int16.max : abs(s)
                if a > peak { peak = a }
            }
        }
        return Float(peak) / Float(Int16.max)
    }

    private static func int16Data(from buffer: AVAudioPCMBuffer) -> Data {
        if buffer.format.commonFormat == .pcmFormatInt16, let ch = buffer.int16ChannelData {
            let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
            return Data(bytes: ch[0], count: count * MemoryLayout<Int16>.size)
        }
        guard let floatCh = buffer.floatChannelData else { return Data() }
        let frames = Int(buffer.frameLength)
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            let f = max(-1, min(1, floatCh[0][i]))
            samples[i] = Int16(f * Float(Int16.max))
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Plays PCM16 mono over the active audio route (glasses HFP or phone speaker).
public final class HFPGlassesAudioEgress: AudioEgress, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private let engineQueue = DispatchQueue(label: "nova.hfp.egress.engine")
    private var started = false
    private var configuredSampleRate: Int = 0

    /// Make-up gain on the Bluetooth HFP call path (quieter than media/A2DP).
    private static let hfpGain: Float = 2.6
    /// Higher make-up when playback is on the built-in speaker/receiver — the
    /// voiceChat path is still quieter than normal media playback on phone.
    private static let speakerGain: Float = 5.2

    public init() {}

    public func enqueue(_ chunk: AudioChunk) async {
        guard chunk.sampleRate > 0, !chunk.pcm.isEmpty else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            engineQueue.async {
                self.ensureStarted(sampleRate: chunk.sampleRate)
                defer { cont.resume() }
                guard let format = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: Double(chunk.sampleRate),
                    channels: 1,
                    interleaved: true
                ) else { return }

                let frameCount = AVAudioFrameCount(chunk.pcm.count / 2)
                guard frameCount > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
                      let channels = buffer.int16ChannelData else { return }
                buffer.frameLength = frameCount

                // Apply route-aware make-up gain with hard limiting into the destination.
                let gain = Self.currentOutputGain()
                let lo = Float(Int16.min), hi = Float(Int16.max)
                let dst = channels[0]
                chunk.pcm.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: Int16.self)
                    let count = min(Int(frameCount), src.count)
                    for i in 0..<count {
                        let amplified = (Float(src[i]) * gain).rounded()
                        dst[i] = Int16(min(hi, max(lo, amplified)))
                    }
                }

                self.player.scheduleBuffer(buffer, completionHandler: nil)
                if !self.player.isPlaying { self.player.play() }
            }
        }
    }

    public func flush() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            engineQueue.async {
                self.player.stop()
                if self.started { self.player.play() }
                cont.resume()
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            engineQueue.async {
                self.player.stop()
                self.engine.stop()
                self.started = false
                self.configuredSampleRate = 0
                cont.resume()
            }
        }
    }

    /// HFP / Bluetooth outputs keep the milder boost; built-in speaker/receiver
    /// get a stronger lift so phone-only listening is usable.
    private static func currentOutputGain() -> Float {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let onBluetooth = outputs.contains {
            $0.portType == .bluetoothHFP
                || $0.portType == .bluetoothA2DP
                || $0.portType == .bluetoothLE
        }
        return onBluetooth ? hfpGain : speakerGain
    }

    private func ensureStarted(sampleRate: Int) {
        // Called on `engineQueue`.
        guard sampleRate > 0 else { return }
        if started {
            // Same rate: keep the running graph. Rate change mid-session is rare
            // (Realtime is fixed at 24 kHz) — rebuild only if needed.
            if configuredSampleRate == sampleRate { return }
            player.stop()
            engine.stop()
            engine.detach(player)
            started = false
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        ) else {
            NovaLog.audio.error("Egress format unavailable for \(sampleRate) Hz")
            return
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
        do {
            try engine.start()
            player.play()
            configuredSampleRate = sampleRate
            started = true
        } catch {
            NovaLog.audio.error("Egress engine start failed: \(String(describing: error), privacy: .public)")
            started = false
            configuredSampleRate = 0
        }
    }
}
#else
public final class HFPGlassesAudioIngress: AudioIngress, MicRouteControlling, @unchecked Sendable {
    public let chunks: AsyncStream<AudioChunk>
    private let continuation: AsyncStream<AudioChunk>.Continuation
    public init(coordinator: AudioSessionCoordinator, metrics: (any LatencyMetricsRecorder)? = nil) {
        var cont: AsyncStream<AudioChunk>.Continuation!
        chunks = AsyncStream(bufferingPolicy: .bufferingNewest(48)) { cont = $0 }
        continuation = cont
    }
    public func start() async throws {}
    public func stop() async { continuation.finish() }
    public func peakLevel() async -> Float { 0 }
    public func inputRouteLabel() async -> String { "unavailable" }
    public func flipPreferredInput() async {}
}

public final class HFPGlassesAudioEgress: AudioEgress, @unchecked Sendable {
    public init() {}
    public func enqueue(_ chunk: AudioChunk) async {}
    public func flush() async {}
    public func stop() async {}
}
#endif

/// Dev/mock ingress that yields silence — useful without glasses.
public final class SilentAudioIngress: AudioIngress, @unchecked Sendable {
    public let chunks: AsyncStream<AudioChunk>
    private let continuation: AsyncStream<AudioChunk>.Continuation
    private var task: Task<Void, Never>?

    public init() {
        var cont: AsyncStream<AudioChunk>.Continuation!
        chunks = AsyncStream(bufferingPolicy: .bufferingNewest(48)) { cont = $0 }
        continuation = cont
    }

    public func start() async throws {
        task = Task {
            while !Task.isCancelled {
                let silence = Data(count: 320 * 2) // 20ms @ 8kHz
                continuation.yield(AudioChunk(pcm: silence, sampleRate: 8_000))
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    public func stop() async {
        task?.cancel()
        continuation.finish()
    }
}
