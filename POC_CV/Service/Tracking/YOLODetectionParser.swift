import CoreGraphics
import CoreML
import Foundation

/// Decodes the end-to-end YOLO output tensor shared by `yolo26n` and
/// `license_nano_model`. Both export with NMS already applied and produce a
/// `[1, N, 6]` tensor where each row is `[x1, y1, x2, y2, score, class]` (or
/// `[cx, cy, w, h, score, class]`), so no additional non-max suppression is
/// required here.
///
/// Box coordinates are auto-detected as either normalised (`0...1`) or expressed
/// in model-input pixels (`0...inputSize`) and are rescaled to the caller's
/// source image dimensions.
enum YOLODetectionParser {
    struct Config {
        /// Pixel size the frame was letterboxed/resized to for the model input.
        let inputSize: CGFloat
        let confidenceThreshold: Float
        let maxDetections: Int
        /// Class indices to keep, or `nil` to accept every class.
        let allowedClassIndices: Set<Int>?
    }

    static func parse(
        output: MLMultiArray,
        sourceSize: CGSize,
        config: Config
    ) -> [VehicleDetection] {
        guard output.shape.count == 3, output.shape[2].intValue >= 5 else { return [] }

        let rowCount = output.shape[1].intValue
        let columnCount = output.shape[2].intValue
        let hasClassColumn = columnCount >= 6

        let normalized = looksNormalized(output, rowCount: rowCount)
        let scaleX = normalized ? sourceSize.width : sourceSize.width / config.inputSize
        let scaleY = normalized ? sourceSize.height : sourceSize.height / config.inputSize
        let sourceRect = CGRect(origin: .zero, size: sourceSize)

        var detections: [VehicleDetection] = []
        detections.reserveCapacity(min(rowCount, config.maxDetections))

        for row in 0..<rowCount {
            let score = value(row: row, column: 4, output: output)
            guard score >= config.confidenceThreshold else { continue }

            let classIndex = hasClassColumn ? Int(value(row: row, column: 5, output: output).rounded()) : 0
            if let allowed = config.allowedClassIndices, allowed.contains(classIndex) == false { continue }

            let a = CGFloat(value(row: row, column: 0, output: output))
            let b = CGFloat(value(row: row, column: 1, output: output))
            let c = CGFloat(value(row: row, column: 2, output: output))
            let d = CGFloat(value(row: row, column: 3, output: output))

            let rect = makeRect(a: a, b: b, c: c, d: d, scaleX: scaleX, scaleY: scaleY)
                .integral
                .intersection(sourceRect)

            guard rect.isNull == false, rect.width > 1, rect.height > 1 else { continue }

            detections.append(VehicleDetection(rect: rect, confidence: score, classIndex: classIndex))
        }

        return Array(
            detections
                .sorted { $0.confidence > $1.confidence }
                .prefix(config.maxDetections)
        )
    }

    // MARK: - Helpers

    /// Distinguishes `[x1, y1, x2, y2]` (corners) from `[cx, cy, w, h]` (centre)
    /// layouts: corner boxes always have `x2 > x1` and `y2 > y1`.
    private static func makeRect(
        a: CGFloat,
        b: CGFloat,
        c: CGFloat,
        d: CGFloat,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> CGRect {
        if c > a, d > b {
            return CGRect(x: a * scaleX, y: b * scaleY, width: (c - a) * scaleX, height: (d - b) * scaleY)
        }
        // centre / size layout
        return CGRect(x: (a - c / 2) * scaleX, y: (b - d / 2) * scaleY, width: c * scaleX, height: d * scaleY)
    }

    private static func looksNormalized(_ output: MLMultiArray, rowCount: Int) -> Bool {
        var maxCoordinate: Float = 0
        for row in 0..<rowCount {
            for column in 0..<4 {
                maxCoordinate = max(maxCoordinate, abs(value(row: row, column: column, output: output)))
            }
        }
        return maxCoordinate <= 1.5
    }

    private static func value(row: Int, column: Int, output: MLMultiArray) -> Float {
        let offset = output.strides[0].intValue * 0
            + output.strides[1].intValue * row
            + output.strides[2].intValue * column
        return output[offset].floatValue
    }
}
