import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Samples evenly spaced JPEG stills from a local movie for Ivy Garden Walk /
/// Identify (and similar vision paths that only accept image frames).
public enum VideoKeyframeSampler {
    /// Returns up to `count` JPEG frames spaced through the movie, or `[]` if
    /// the asset cannot be read / has no duration. Near-duplicate frames are dropped.
    public static func jpegKeyFrames(
        from url: URL,
        count: Int = 3,
        maxDimension: CGFloat = 1280,
        compressionQuality: CGFloat = 0.78
    ) async -> [Data] {
        #if canImport(AVFoundation) && canImport(UIKit)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        let duration: Double
        do {
            let cm = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cm)
        } catch {
            return []
        }
        guard duration.isFinite, duration > 0 else { return [] }
        // Oversample slightly, then dedupe near-identical stills.
        let steps = max(count, 1)
        let sampleCount = min(steps * 2, max(steps, 24))
        var frames: [Data] = []
        for i in 0..<sampleCount {
            let t = duration * (Double(i) + 0.5) / Double(sampleCount)
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
                let image = UIImage(cgImage: cg)
                if let data = image.jpegData(compressionQuality: compressionQuality) {
                    frames.append(data)
                }
            }
        }
        return dedupeFrames(frames, maxKeep: steps)
        #else
        return []
        #endif
    }

    /// Picks a frame count from movie length (about one every ~4s).
    /// Catalog mode uses a higher cap so more plants are likely to appear.
    public static func suggestedFrameCount(durationSeconds: Double, catalog: Bool = false) -> Int {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return 3 }
        let cap = catalog ? 12 : 8
        return min(cap, max(3, Int((durationSeconds / 4.0).rounded(.up))))
    }

    public static func jpegKeyFramesAdaptive(from url: URL, catalog: Bool = false) async -> [Data] {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        let duration: Double
        do {
            let cm = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cm)
        } catch {
            return []
        }
        return await jpegKeyFrames(
            from: url,
            count: suggestedFrameCount(durationSeconds: duration, catalog: catalog),
            maxDimension: catalog ? 1536 : 1280,
            compressionQuality: catalog ? 0.82 : 0.78
        )
        #else
        return await jpegKeyFrames(from: url, count: catalog ? 6 : 3)
        #endif
    }

    /// Drops near-duplicate JPEGs using a tiny grayscale fingerprint.
    public static func dedupeFrames(_ frames: [Data], maxKeep: Int) -> [Data] {
        guard maxKeep > 0, !frames.isEmpty else { return [] }
        var kept: [Data] = []
        var fingerprints: [[UInt8]] = []
        for frame in frames {
            guard let fp = fingerprint(frame) else {
                if kept.count < maxKeep { kept.append(frame) }
                continue
            }
            let isDup = fingerprints.contains { existing in
                meanAbsoluteDifference(existing, fp) < 12
            }
            if isDup { continue }
            fingerprints.append(fp)
            kept.append(frame)
            if kept.count >= maxKeep { break }
        }
        // If dedupe was too aggressive, fall back to evenly spaced originals.
        if kept.count < min(maxKeep, frames.count), frames.count >= maxKeep {
            var evenly: [Data] = []
            for i in 0..<maxKeep {
                let idx = Int((Double(i) + 0.5) / Double(maxKeep) * Double(frames.count))
                evenly.append(frames[min(idx, frames.count - 1)])
            }
            return evenly
        }
        return kept
    }

    // MARK: - Private

    private static func fingerprint(_ data: Data) -> [UInt8]? {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            let size = CGSize(width: 8, height: 8)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            if let tiny = small.jpegData(compressionQuality: 0.5) {
                return coarseByteFingerprint(tiny)
            }
        }
        #endif
        return coarseByteFingerprint(data)
    }

    private static func coarseByteFingerprint(_ data: Data) -> [UInt8]? {
        guard data.count > 64 else { return nil }
        var values: [UInt8] = []
        values.reserveCapacity(64)
        let step = max(data.count / 64, 1)
        for i in 0..<64 {
            let offset = min(i * step, data.count - 1)
            values.append(data[data.index(data.startIndex, offsetBy: offset)])
        }
        return values
    }

    private static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return Double.greatestFiniteMagnitude }
        var sum = 0
        for i in 0..<n {
            sum += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(sum) / Double(n)
    }
}
