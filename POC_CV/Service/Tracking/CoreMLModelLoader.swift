import CoreML
import Foundation

/// Errors surfaced while locating or loading a bundled CoreML asset.
enum CoreMLAssetError: LocalizedError {
    case modelNotFound(String)
    case resourceNotFound(String)
    case missingImageInput(String)
    case missingMultiArrayOutput(String)
    case invalidInputImage

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):
            return "Unable to find CoreML model \(name) in the app bundle."
        case .resourceNotFound(let name):
            return "Unable to find bundled resource \(name)."
        case .missingImageInput(let name):
            return "Model \(name) does not expose an image input feature."
        case .missingMultiArrayOutput(let name):
            return "Model \(name) did not produce the expected multi-array output."
        case .invalidInputImage:
            return "Unable to build a pixel buffer for the model input."
        }
    }
}

/// Centralises bundle lookup + compilation for every CoreML asset used by the
/// tracking pipeline so the individual detectors do not each re-implement the
/// (surprisingly fiddly) resolution logic. All models live under `Assets/coreml`.
enum CoreMLModelLoader {
    private enum Constants {
        static let compiledExtension = "mlmodelc"
        static let packageExtension = "mlpackage"
        static let modelSubdirectory = "Assets/coreml"
        static let assetSubdirectory = "Assets"
    }

    /// Loads (and compiles on first use) a model bundled either as a compiled
    /// `.mlmodelc` or as a raw `.mlpackage`.
    static func loadModel(named name: String, configuration: MLModelConfiguration) throws -> MLModel {
        let url = try resolveModelURL(named: name)
        let loadURL = url.pathExtension == Constants.packageExtension
            ? try MLModel.compileModel(at: url)
            : url
        return try MLModel(contentsOf: loadURL, configuration: configuration)
    }

    static func resolveModelURL(named name: String) throws -> URL {
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: Constants.compiledExtension),
            Bundle.main.url(forResource: name, withExtension: Constants.compiledExtension, subdirectory: Constants.modelSubdirectory),
            Bundle.main.url(forResource: name, withExtension: Constants.packageExtension),
            Bundle.main.url(forResource: name, withExtension: Constants.packageExtension, subdirectory: Constants.modelSubdirectory)
        ]
        if let url = candidates.compactMap({ $0 }).first {
            return url
        }
        throw CoreMLAssetError.modelNotFound(name)
    }

    static func resolveResourceURL(named name: String, extension ext: String) throws -> URL {
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: ext),
            Bundle.main.url(forResource: name, withExtension: ext, subdirectory: Constants.assetSubdirectory),
            Bundle.main.resourceURL?.appendingPathComponent("\(name).\(ext)"),
            Bundle.main.resourceURL?.appendingPathComponent(Constants.assetSubdirectory).appendingPathComponent("\(name).\(ext)")
        ]
        if let url = candidates.compactMap({ $0 }).first, FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        throw CoreMLAssetError.resourceNotFound("\(name).\(ext)")
    }

    static func makeConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        // Let CoreML place work on the Neural Engine when the (FP16/INT8) model
        // supports it, falling back to GPU/CPU otherwise.
        configuration.computeUnits = .all
        return configuration
    }
}

extension MLModel {
    /// Name of the first image input feature, if any.
    var firstImageInputName: String? {
        modelDescription.inputDescriptionsByName.first { $0.value.imageConstraint != nil }?.key
    }

    /// Pixel dimensions required by the first (or named) image input feature.
    func imageInputSize(for featureName: String? = nil) -> (width: Int, height: Int)? {
        for (name, description) in modelDescription.inputDescriptionsByName {
            if let featureName, name != featureName { continue }
            if let constraint = description.imageConstraint {
                return (constraint.pixelsWide, constraint.pixelsHigh)
            }
        }
        return nil
    }

    /// Name of the first multi-array output feature, if any. Used so detectors do
    /// not have to hard-code the auto-generated tensor names (`var_1441`, ...).
    var firstMultiArrayOutputName: String? {
        modelDescription.outputDescriptionsByName.first { $0.value.multiArrayConstraint != nil }?.key
    }
}
