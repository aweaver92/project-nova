import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Crops a garden photo down to one plant using a normalized bounding box.
public enum PlantImageIsolator {
    /// JPEG crop with light padding so leaves/stems aren’t clipped at the edge.
    public static func cropJPEG(
        _ imageData: Data,
        box: PlantBoundingBox,
        padding: Double = 0.08,
        quality: Double = 0.88
    ) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: imageData),
              let cg = image.cgImage
        else { return nil }
        let width = cg.width
        let height = cg.height
        guard let rect = box.pixelRect(imageWidth: width, imageHeight: height, padding: padding)
        else { return nil }
        // Nearly full-frame — keep the original bytes.
        let coverage = Double(rect.width * rect.height) / Double(max(1, width * height))
        if coverage >= 0.92 { return imageData }

        let crop = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        guard let cropped = cg.cropping(to: crop) else { return nil }
        let ui = UIImage(cgImage: cropped, scale: 1, orientation: image.imageOrientation)
        return ui.jpegData(compressionQuality: CGFloat(quality)) ?? imageData
        #else
        return imageData
        #endif
    }
}
