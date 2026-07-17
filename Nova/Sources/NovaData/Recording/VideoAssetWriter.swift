import Foundation
import NovaCore
import NovaDomain

#if canImport(AVFoundation) && canImport(UIKit) && os(iOS)
import AVFoundation
import CoreVideo
import UIKit

/// Assembles JPEG frames pulled from the glasses live-look into an H.264 `.mp4`
/// via `AVAssetWriter`. Frames are timestamped by wall-clock elapsed time, so the
/// movie plays back in real time even though the glasses only deliver a few
/// frames per second.
///
/// Not `Sendable`: it is created and used entirely inside `GlassesVideoRecorder`'s
/// actor isolation, so it never crosses concurrency domains.
final class VideoAssetWriter {
    let url: URL
    let width: Int
    let height: Int
    private(set) var frameCount = 0
    private(set) var lastSeconds: TimeInterval = 0

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false

    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        // H.264 requires even dimensions.
        self.width = max(2, width - (width % 2))
        self.height = max(2, height - (height % 2))

        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: self.width,
            AVVideoHeightKey: self.height
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: self.width,
            kCVPixelBufferHeightKey as String: self.height
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { throw NovaError.vision("Cannot add video writer input") }
        writer.add(input)
    }

    /// Append one frame at `seconds` elapsed since recording start.
    func append(jpeg: Data, at seconds: TimeInterval) {
        guard let cg = UIImage(data: jpeg)?.cgImage else { return }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: .zero)
            started = true
        }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }

        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let pb = pbOut else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        if adaptor.append(pb, withPresentationTime: time) {
            frameCount += 1
            lastSeconds = seconds
        }
    }

    /// Finish writing and flush to disk. Returns true if a valid movie was written.
    func finalize() async -> Bool {
        guard started else {
            writer.cancelWriting()
            return false
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: lastSeconds, preferredTimescale: 600))
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        return writer.status == .completed
    }
}

#else

/// Fallback used when AVFoundation/UIKit isn't available (non-iOS builds). Keeps
/// `GlassesVideoRecorder` compiling; produces no output.
final class VideoAssetWriter {
    let url: URL
    let width: Int
    let height: Int
    private(set) var frameCount = 0
    private(set) var lastSeconds: TimeInterval = 0

    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        self.width = width
        self.height = height
    }

    func append(jpeg: Data, at seconds: TimeInterval) {}
    func finalize() async -> Bool { false }
}

#endif
