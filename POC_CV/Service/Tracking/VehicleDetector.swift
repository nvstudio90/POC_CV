import CoreGraphics
import CoreML
import Foundation

/// Stage 1 of the hierarchical pipeline: full-frame vehicle detection using the
/// quantised `yolo26n` model (640×640 image input, `[1, 300, 6]` output).
///
/// Synchronous by design — it is always invoked from the detector serial queue
/// owned by `AsyncDetectionCoordinator`, never from the render thread.
final class VehicleDetector {
    private enum Constants {
        static let modelName = "yolo26n"
        static let fallbackInputSize = 640
        static let confidenceThreshold: Float = 0.35
        static let maxDetections = 20
        /// `nil` accepts every class the model emits. Set to COCO vehicle ids
        /// `[2, 3, 5, 7]` (car/motorcycle/bus/truck) if using a COCO export.
        static let allowedClassIndices: Set<Int>? = nil
    }

    private let configuration: MLModelConfiguration
    private var model: MLModel?
    private var inputName = "image"
    private var inputSize = Constants.fallbackInputSize
    private var outputName: String?

    init(configuration: MLModelConfiguration = CoreMLModelLoader.makeConfiguration()) {
        self.configuration = configuration
    }

    /// Runs vehicle detection on a source frame. `image` is the full-resolution
    /// frame; returned rects are in its image space (top-left origin, pixels).
    func detectVehicles(in image: CGImage) throws -> [VehicleDetection] {
        let model = try loadModelIfNeeded()

        let inputValue = try MLFeatureValue(
            cgImage: image,
            pixelsWide: inputSize,
            pixelsHigh: inputSize,
            pixelFormatType: kCVPixelFormatType_32ARGB,
            options: nil
        )
        guard let pixelBuffer = inputValue.imageBufferValue else {
            throw CoreMLAssetError.invalidInputImage
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(pixelBuffer: pixelBuffer)
        ])
        let prediction = try model.prediction(from: provider)

        guard let outputName,
              let multiArray = prediction.featureValue(for: outputName)?.multiArrayValue else {
            throw CoreMLAssetError.missingMultiArrayOutput(Constants.modelName)
        }

        return YOLODetectionParser.parse(
            output: multiArray,
            sourceSize: CGSize(width: image.width, height: image.height),
            config: .init(
                inputSize: CGFloat(inputSize),
                confidenceThreshold: Constants.confidenceThreshold,
                maxDetections: Constants.maxDetections,
                allowedClassIndices: Constants.allowedClassIndices
            )
        )
    }

    private func loadModelIfNeeded() throws -> MLModel {
        if let model { return model }

        let loaded = try CoreMLModelLoader.loadModel(named: Constants.modelName, configuration: configuration)
        inputName = loaded.firstImageInputName ?? inputName
        if let size = loaded.imageInputSize(for: inputName) {
            inputSize = size.width
        }
        outputName = loaded.firstMultiArrayOutputName
        model = loaded
        return loaded
    }
}
