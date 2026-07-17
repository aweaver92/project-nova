import Foundation
import NovaCore
import NovaDomain

#if canImport(Speech) && os(iOS)
import Speech
import AVFoundation

/// On-device wake-word listener built on Apple's Speech framework. It keeps the
/// microphone open (preferring the glasses' HFP route) and runs continuous,
/// on-device recognition, emitting a detection each time the wake word is heard.
///
/// Apple limits a single recognition task's duration, so the task is transparently
/// restarted on completion/error to stay always-on. Recognition is forced
/// on-device (`requiresOnDeviceRecognition`) for privacy and to avoid cloud limits.
public final class SpeechWakeWordDetector: WakeWordListening, @unchecked Sendable {
    public let detections: AsyncStream<Void>
    private let detectionsCont: AsyncStream<Void>.Continuation

    private let recognizer: SFSpeechRecognizer?
    private let detector: WakeWordDetector
    private let engine = AVAudioEngine()
    private let lock = NSLock()

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false

    public init(wakeWord: String = "Nova", locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        // Vision phrases are irrelevant here; we only need wake-word presence.
        self.detector = WakeWordDetector(wakeWord: wakeWord, visionPhrases: [])
        var cont: AsyncStream<Void>.Continuation!
        self.detections = AsyncStream { cont = $0 }
        self.detectionsCont = cont
    }

    public func start() async throws {
        guard let recognizer, recognizer.isAvailable else {
            throw NovaError.audioSession("Speech recognizer unavailable")
        }
        try await ensureAuthorized()
        try configureSession()
        lock.lock(); running = true; lock.unlock()
        try startRecognition()
        NovaLog.audio.info("Speech wake-word detector started")
    }

    public func stop() async {
        lock.lock(); running = false; lock.unlock()
        endRecognition()
        NovaLog.audio.info("Speech wake-word detector stopped")
    }

    private func ensureAuthorized() async throws {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw NovaError.credentials("Speech recognition not authorized")
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            if let hfp = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try? session.setPreferredInput(hfp)
            }
        } catch {
            throw NovaError.audioSession(String(describing: error))
        }
    }

    private func startRecognition() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw NovaError.audioSession(String(describing: error))
        }

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                let intent = self.detector.detect(text)
                // A bare "Nova, stop" should never wake an idle session — it only
                // means something while Nova is already engaged/speaking.
                if intent != .ignore, intent != .stop {
                    self.detectionsCont.yield(())
                    self.restart()
                    return
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                self.restart()
            }
        }
    }

    private func endRecognition() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    /// Restart the recognition task so listening stays always-on despite Apple's
    /// per-task duration limits.
    private func restart() {
        endRecognition()
        lock.lock(); let alive = running; lock.unlock()
        guard alive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let stillAlive = self.running; self.lock.unlock()
            guard stillAlive else { return }
            try? self.startRecognition()
        }
    }
}
#else
/// Non-iOS fallback: a listener that never fires, so the orchestrator falls back
/// to always-on streaming.
public final class SpeechWakeWordDetector: WakeWordListening, @unchecked Sendable {
    public let detections: AsyncStream<Void>
    public init(wakeWord: String = "Nova", locale: Locale = Locale(identifier: "en-US")) {
        self.detections = AsyncStream { $0.finish() }
    }
    public func start() async throws {}
    public func stop() async {}
}
#endif
