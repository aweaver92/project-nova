import Foundation
import NovaCore
import NovaDomain

/// Records video from the Meta glasses camera by consuming the `FrameCapture`
/// live-look and assembling frames into an `.mp4` (see `VideoAssetWriter`).
///
/// This does NOT depend on the Meta AI vision integration — it uses the same DAT
/// camera stream Nova already opens for stills, so it works as long as the
/// glasses are registered and camera access is granted.
public actor GlassesVideoRecorder: VideoRecorder {
    private let store: any VideoRecordingStoring
    private let capture: any FrameCapture
    private let fps: Int

    private var writer: VideoAssetWriter?
    private var startedAt: Date?
    private var outputURL: URL?
    private var frameTask: Task<Void, Never>?

    private let stateStream: AsyncStream<VideoRecordingState>
    private let stateContinuation: AsyncStream<VideoRecordingState>.Continuation

    public nonisolated var state: AsyncStream<VideoRecordingState> { stateStream }

    public init(store: any VideoRecordingStoring, capture: any FrameCapture, fps: Int = 2) {
        self.store = store
        self.capture = capture
        self.fps = fps
        (self.stateStream, self.stateContinuation) = AsyncStream.makeStream(
            of: VideoRecordingState.self,
            bufferingPolicy: .bufferingNewest(4)
        )
        stateContinuation.yield(.idle)
    }

    public func isRecording() -> Bool { writer != nil || frameTask != nil }

    public func start() async throws {
        guard frameTask == nil else { return }
        let now = Date()
        let directory = await store.directory()
        let url = directory.appendingPathComponent(Self.fileName(for: now))
        self.outputURL = url
        self.startedAt = now
        self.writer = nil

        await capture.prewarm()
        let frames = try await capture.startLiveLook(fps: fps)

        stateContinuation.yield(.recording(startedAt: now))
        NovaLog.vision.info("Video recording started → \(url.lastPathComponent, privacy: .public)")

        frameTask = Task { [weak self] in
            for await frame in frames {
                await self?.appendFrame(frame, since: now, url: url)
            }
        }
    }

    private func appendFrame(_ frame: CapturedFrame, since start: Date, url: URL) {
        if writer == nil {
            guard frame.width > 0, frame.height > 0 else { return }
            writer = try? VideoAssetWriter(url: url, width: frame.width, height: frame.height)
        }
        writer?.append(jpeg: frame.imageData, at: Date().timeIntervalSince(start))
    }

    @discardableResult
    public func stop() async -> VideoRecording? {
        guard let startedAt, let url = outputURL else { return nil }
        frameTask?.cancel()
        frameTask = nil
        await capture.stopLiveLook()

        let writer = self.writer
        self.writer = nil
        self.startedAt = nil
        self.outputURL = nil
        stateContinuation.yield(.idle)

        guard let writer else {
            NovaLog.vision.info("Video recording stopped before any frame; discarded")
            return nil
        }
        let ok = await writer.finalize()
        let frameCount = writer.frameCount
        guard ok, frameCount > 0 else {
            try? FileManager.default.removeItem(at: url)
            NovaLog.vision.info("Video recording produced no frames; discarded")
            return nil
        }

        let duration = Date().timeIntervalSince(startedAt)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attrs?[.size] as? Int) ?? 0
        let recording = VideoRecording(
            fileName: url.lastPathComponent,
            createdAt: startedAt,
            duration: duration,
            width: writer.width,
            height: writer.height,
            frameCount: frameCount,
            byteCount: byteCount
        )
        NovaLog.vision.info("Video recording saved (\(Int(duration), privacy: .public)s, \(frameCount, privacy: .public) frames)")
        return await store.register(recording)
    }

    private static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "nova-video-\(formatter.string(from: date)).mp4"
    }
}
