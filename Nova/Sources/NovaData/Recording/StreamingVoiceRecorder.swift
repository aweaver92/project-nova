import Foundation
import NovaCore
import NovaDomain

/// Records the microphone feed to a WAV file by consuming PCM chunks teed from
/// the conversation pipeline (see `ConversationOrchestrator`). Because it never
/// opens its own audio session, it can record while a live conversation is
/// running without fighting over the single HFP route.
public actor StreamingVoiceRecorder: VoiceRecorder {
    private let store: any RecordingStoring
    /// Fixed capture rate: the glasses/phone HFP mic delivers narrowband 8 kHz
    /// mono PCM16 (see `HFPGlassesAudioIngress`).
    private let sampleRate: Int

    private var writer: WAVWriter?
    private var startedAt: Date?

    private let stateStream: AsyncStream<VoiceRecordingState>
    private let stateContinuation: AsyncStream<VoiceRecordingState>.Continuation

    public nonisolated var state: AsyncStream<VoiceRecordingState> { stateStream }

    public init(store: any RecordingStoring, sampleRate: Int = 8_000) {
        self.store = store
        self.sampleRate = sampleRate
        (self.stateStream, self.stateContinuation) = AsyncStream.makeStream(
            of: VoiceRecordingState.self,
            bufferingPolicy: .bufferingNewest(4)
        )
        stateContinuation.yield(.idle)
    }

    public func isRecording() -> Bool { writer != nil }

    public func start() async throws {
        guard writer == nil else { return }
        let now = Date()
        let directory = await store.directory()
        let url = directory.appendingPathComponent(Self.fileName(for: now))
        let writer = try WAVWriter(url: url, sampleRate: sampleRate)
        self.writer = writer
        self.startedAt = now
        stateContinuation.yield(.recording(startedAt: now))
        NovaLog.audio.info("Voice recording started → \(url.lastPathComponent, privacy: .public)")
    }

    public func append(_ chunk: AudioChunk) async {
        guard let writer else { return }
        // The tee only forwards the narrowband mic feed; ignore anything that
        // isn't at our capture rate so the header stays truthful.
        guard chunk.sampleRate == sampleRate else { return }
        try? writer.append(chunk.pcm)
    }

    @discardableResult
    public func stop() async -> VoiceRecording? {
        guard let writer, let startedAt else { return nil }
        self.writer = nil
        self.startedAt = nil

        let bytes = writer.bytesWritten
        writer.finalize()
        stateContinuation.yield(.idle)

        guard bytes > 0 else {
            // Nothing captured (e.g. mic pipeline wasn't running) — drop the empty file.
            try? FileManager.default.removeItem(at: writer.url)
            NovaLog.audio.info("Voice recording stopped with no audio; discarded")
            return nil
        }

        let sampleCount = bytes / MemoryLayout<Int16>.size
        let duration = Double(sampleCount) / Double(sampleRate)
        let recording = VoiceRecording(
            fileName: writer.url.lastPathComponent,
            createdAt: startedAt,
            duration: duration,
            sampleRate: sampleRate,
            byteCount: bytes
        )
        NovaLog.audio.info("Voice recording saved (\(Int(duration), privacy: .public)s, \(bytes, privacy: .public) bytes)")
        return await store.register(recording)
    }

    private static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "nova-recording-\(formatter.string(from: date)).wav"
    }
}
