import CoreGraphics
import Foundation

/// Coordinate-system helpers bridging three spaces used across the pipeline:
///
/// - **Image space**: pixels, origin top-left. Used by CoreML detector outputs,
///   `CGImage` cropping and the overlay renderer.
/// - **Vision space**: normalised `[0, 1]`, origin bottom-left. Used by
///   `VNTrackObjectRequest` / `VNDetectedObjectObservation`.
///
/// Keeping the conversions in one place avoids the classic "boxes are flipped /
/// mirrored" bugs when data crosses between CoreML and Vision.
enum VisionGeometry {
    /// Image-space rect (top-left origin, pixels) → Vision normalised rect
    /// (bottom-left origin).
    static func normalizedRect(fromImageRect rect: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let x = rect.minX / imageSize.width
        let width = rect.width / imageSize.width
        let height = rect.height / imageSize.height
        let y = (imageSize.height - rect.maxY) / imageSize.height
        return CGRect(x: x, y: y, width: width, height: height).clampedToUnitSquare()
    }

    /// Vision normalised rect (bottom-left origin) → image-space rect (top-left
    /// origin, pixels).
    static func imageRect(fromNormalizedRect rect: CGRect, imageSize: CGSize) -> CGRect {
        let x = rect.minX * imageSize.width
        let width = rect.width * imageSize.width
        let height = rect.height * imageSize.height
        let y = (1 - rect.maxY) * imageSize.height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Intersection-over-union of two image-space rects. Used to associate fresh
    /// detections with existing tracks.
    static func iou(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard intersection.isNull == false else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
}

extension CGRect {
    func clampedToUnitSquare() -> CGRect {
        let minX = Swift.max(0, Swift.min(1, self.minX))
        let minY = Swift.max(0, Swift.min(1, self.minY))
        let maxX = Swift.max(0, Swift.min(1, self.maxX))
        let maxY = Swift.max(0, Swift.min(1, self.maxY))
        return CGRect(x: minX, y: minY, width: Swift.max(0, maxX - minX), height: Swift.max(0, maxY - minY))
    }

    /// Uniformly grows the rect by `ratio` around its centre, clamped to `bounds`.
    /// Used to pad vehicle crops so the plate is never clipped at the edge.
    func expanded(by ratio: CGFloat, within bounds: CGRect) -> CGRect {
        let dx = width * ratio
        let dy = height * ratio
        return insetBy(dx: -dx, dy: -dy).intersection(bounds)
    }
}
