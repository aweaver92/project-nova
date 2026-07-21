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
    /// the asset cannot be read / has no duration.
    public static func jpegKeyFrames(
        from url: URL,
        count: Int = 3,
        maxDimension: CGFloat = 1280,
        compressionQuality: CGFloat = 0.7
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
        var frames: [Data] = []
        let steps = max(count, 1)
        for i in 0..<steps {
            let t = duration * (Double(i) + 0.5) / Double(steps)
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
                let image = UIImage(cgImage: cg)
                if let data = image.jpegData(compressionQuality: compressionQuality) {
                    frames.append(data)
                }
            }
        }
        return frames
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
            count: suggestedFrameCount(durationSeconds: duration, catalog: catalog)
        )
        #else
        return await jpegKeyFrames(from: url, count: catalog ? 6 : 3)
        #endif
    }
}
