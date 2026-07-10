import CoreGraphics
import CoreML
import Foundation

/// Stage 2 of the hierarchical pipeline: locate the license plate *inside* an
/// already-cropped vehicle image using the `license_nano_model` (320×320 image
/// input, `[1, 300, 6]` output).
///
/// Returned rects are in the coordinate space of the supplied crop (top-left
/// origin, pixels of the crop). The caller is responsible for mapping them back
/// to the full frame.
final class LicensePlateLocator {
    private enum Constants {
        static let modelName = "license_nano_model"
        static let fallbackInputSize = 320
        static let confidenceThreshold: Float = 0.30
        static let maxDetections = 5
    }

    private let configuration: MLModelConfiguration
    private var model: MLModel?
    private var inputName = "image"
    private var inputSize = Constants.fallbackInputSize
    private var outputName: String?

    init(configuration: MLModelConfiguration = CoreMLModelLoader.makeConfiguration()) {
        self.configuration = configuration
    }

    /// Returns the highest-confidence plate rect within `vehicleCrop`, or `nil`
    /// if none clears the threshold.
    func locatePlate(in vehicleCrop: CGImage) throws -> VehicleDetection? {
        let model = try loadModelIfNeeded()

        let inputValue = try MLFeatureValue(
            cgImage: vehicleCrop,
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

        let plates = YOLODetectionParser.parse(
            output: multiArray,
            sourceSize: CGSize(width: vehicleCrop.width, height: vehicleCrop.height),
            config: .init(
                inputSize: CGFloat(inputSize),
                confidenceThreshold: Constants.confidenceThreshold,
                maxDetections: Constants.maxDetections,
                allowedClassIndices: nil
            )
        )

        return plates.max { $0.confidence < $1.confidence }
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
