import Foundation

/// Normalized plant region in an image (origin top-left, values 0…1).
public struct PlantBoundingBox: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        width > 0.02 && height > 0.02
            && x < 1 && y < 1
            && width <= 1.05 && height <= 1.05
    }

    public var area: Double { max(0, width) * max(0, height) }

    public func clamped() -> PlantBoundingBox {
        let nx = min(max(x, 0), 0.98)
        let ny = min(max(y, 0), 0.98)
        let nw = min(max(width, 0.02), 1 - nx)
        let nh = min(max(height, 0.02), 1 - ny)
        return PlantBoundingBox(x: nx, y: ny, width: nw, height: nh)
    }

    public func iou(with other: PlantBoundingBox) -> Double {
        let a = clamped()
        let b = other.clamped()
        let x1 = max(a.x, b.x)
        let y1 = max(a.y, b.y)
        let x2 = min(a.x + a.width, b.x + b.width)
        let y2 = min(a.y + a.height, b.y + b.height)
        let interW = max(0, x2 - x1)
        let interH = max(0, y2 - y1)
        let inter = interW * interH
        let union = a.area + b.area - inter
        guard union > 0 else { return 0 }
        return inter / union
    }

    /// Pixel crop rect in image coordinates, with optional normalized padding.
    public func pixelRect(
        imageWidth: Int,
        imageHeight: Int,
        padding: Double = 0.08
    ) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard imageWidth > 0, imageHeight > 0, isValid else { return nil }
        let box = clamped()
        let padX = box.width * padding
        let padY = box.height * padding
        let left = max(0.0, box.x - padX)
        let top = max(0.0, box.y - padY)
        let right = min(1.0, box.x + box.width + padX)
        let bottom = min(1.0, box.y + box.height + padY)
        let px = Int((left * Double(imageWidth)).rounded(.down))
        let py = Int((top * Double(imageHeight)).rounded(.down))
        let pr = Int((right * Double(imageWidth)).rounded(.up))
        let pb = Int((bottom * Double(imageHeight)).rounded(.up))
        let w = max(1, min(imageWidth - px, pr - px))
        let h = max(1, min(imageHeight - py, pb - py))
        guard w >= 8, h >= 8 else { return nil }
        return (px, py, w, h)
    }
}
