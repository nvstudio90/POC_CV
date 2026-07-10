import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

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
    /// Derives the `CGImagePropertyOrientation` Vision/CoreML need from an
    /// `AVAssetTrack.preferredTransform`. Only the rotation component matters
    /// here (the translation term is a pixel-space offset that doesn't apply
    /// to unrotated buffers), so only pure 0/90/180/270° rotations are
    /// recognised; anything else falls back to `.up`.
    static func orientation(fromPreferredTransform transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0):
            return .right
        case (0, -1, 1, 0):
            return .left
        case (-1, 0, 0, -1):
            return .down
        default:
            return .up
        }
    }

    /// A pure-rotation `CGAffineTransform` (no translation) suitable for
    /// applying to a `CALayer` so an *unrotated* pixel buffer displays upright.
    static func displayRotationTransform(for orientation: CGImagePropertyOrientation) -> CGAffineTransform {
        switch orientation {
        case .right:
            return CGAffineTransform(rotationAngle: .pi / 2)
        case .left:
            return CGAffineTransform(rotationAngle: -.pi / 2)
        case .down:
            return CGAffineTransform(rotationAngle: .pi)
        default:
            return .identity
        }
    }

    /// The pixel size of `pixelBuffer` *as it will be displayed* once
    /// `orientation` is applied (width/height swap for the 90°/270° cases).
    /// This is the same "image space" every other rect in the pipeline is
    /// expressed in.
    static func orientedImageSize(of pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CGSize {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return orientation.swapsWidthAndHeight
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

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

extension CGImagePropertyOrientation {
    /// `true` for the 90°/270° rotations, where width and height swap between
    /// the buffer's raw storage space and its oriented (display) space.
    var swapsWidthAndHeight: Bool {
        switch self {
        case .left, .right, .leftMirrored, .rightMirrored:
            return true
        default:
            return false
        }
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
