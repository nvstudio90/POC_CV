import CoreImage
import CoreVideo
import Foundation
import Metal

/// Renders the (pooled, short-lived) `CVPixelBuffer`s handed out by
/// `AVPlayerItemVideoOutput` into freshly-allocated, self-owned `32BGRA`
/// buffers, entirely on the GPU via Core Image.
///
/// Why this exists — feeding the raw video-output buffer straight into the
/// tracking/detection pipeline was the source of a nasty class of bug: that
/// buffer belongs to `AVPlayerItemVideoOutput`'s internal pool, but the design
/// retains it across several async hops (Vision optical-flow tracking, the
/// throttled CoreML detector held as `pendingFrame`, and plate OCR that runs
/// much later). While a buffer is still referenced downstream the pool can
/// recycle/overwrite its backing `IOSurface`, so by the time YOLO/OCR actually
/// read it they see stale or half-overwritten pixels — detection and tracking
/// silently fail.
///
/// The converted buffer comes from a pool this class owns, so it is completely
/// decoupled from the AV output pool: safe to retain across every async hop and
/// it never starves the video output of buffers. Core Image performs the copy
/// on the GPU (`CIContext` is Metal-backed), so this stays cheap on the hot
/// capture path.
///
/// Not thread-safe: call from a single serial queue (the capture path does).
final class PixelBufferConverter {
    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    init() {
        // Disable color management (`workingColorSpace: NSNull`). Without this,
        // Core Image renders in its *linear* working space and — because we ask
        // for no output color matching below — writes those linear samples raw
        // into the buffer. The display then interprets them as sRGB, which makes
        // the whole frame noticeably darker, and the detector reads those same
        // wrong pixels, so YOLO/OCR stop recognising anything. With color
        // management off, the BGRA→BGRA render is a straight byte-for-byte copy:
        // identical pixels to the old CGImage path, just kept as a buffer.
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .cacheIntermediates: false
        ]

        // Prefer an explicit Metal-backed context so the conversion runs on the
        // GPU; fall back to the default (still GPU-backed on-device) otherwise.
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    /// Renders `source` into a self-owned `32BGRA` buffer of the same pixel
    /// dimensions. The buffer is *not* rotated — it stays in the same unrotated
    /// space the rest of the pipeline expects, with orientation applied
    /// downstream by Vision/CoreML and the display layer. Returns `nil` only if
    /// buffer allocation fails.
    func convertToBGRA(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0,
              let pool = pool(width: width, height: height) else {
            return nil
        }

        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
              let output else {
            return nil
        }

        // `colorSpace: nil` asks for no output color matching; paired with the
        // color-managed-off context (see `init`) the render is a raw BGRA→BGRA
        // copy — no gamma shift, no darkening.
        let image = CIImage(cvPixelBuffer: source)
        context.render(image, to: output, bounds: image.extent, colorSpace: nil)
        return output
    }

    /// Lazily (re)builds the output pool, recreating it when the frame size
    /// changes (e.g. a new video is loaded).
    private func pool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool, poolWidth == width, poolHeight == height {
            return pool
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        var newPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool) == kCVReturnSuccess else {
            return nil
        }

        pool = newPool
        poolWidth = width
        poolHeight = height
        return newPool
    }
}
