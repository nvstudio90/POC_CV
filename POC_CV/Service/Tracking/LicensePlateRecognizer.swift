import CoreGraphics
import CoreML
import Foundation

/// Stage 3 of the hierarchical pipeline: read the characters on a tightly
/// cropped, full-resolution plate image using `latin_PP-OCRv5_mobile_rec`
/// (multi-array input `[1, 3, 48, 320]`, CTC output `[1, 40, 838]`).
///
/// Recognition is intentionally expensive relative to tracking, so callers run
/// it sparingly — ideally once, when the plate reaches its largest on-screen
/// size — and cache the result against the vehicle id.
final class LicensePlateRecognizer {
    struct Reading {
        let text: String
        let confidence: Float
    }

    private enum Constants {
        static let modelName = "latin_PP-OCRv5_mobile_rec"
        static let dictionaryName = "ppocrv5_latin_dict"
        static let dictionaryExtension = "txt"
        static let inputName = "x"
        static let inputWidth = 320
        static let inputHeight = 48
        static let channelCount = 3
        static let ctcBlankIndex = 0
    }

    private let configuration: MLModelConfiguration
    private var model: MLModel?
    private var outputName: String?
    private var characters: [String]?

    init(configuration: MLModelConfiguration = CoreMLModelLoader.makeConfiguration()) {
        self.configuration = configuration
    }

    /// Reads text from a plate crop taken from the full-resolution frame.
    func recognize(plateImage: CGImage) throws -> Reading? {
        let model = try loadModelIfNeeded()
        let characters = try loadCharactersIfNeeded()

        guard let inputArray = makeInput(from: plateImage) else { return nil }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            Constants.inputName: MLFeatureValue(multiArray: inputArray)
        ])
        let prediction = try model.prediction(from: provider)

        guard let outputName,
              let output = prediction.featureValue(for: outputName)?.multiArrayValue else {
            throw CoreMLAssetError.missingMultiArrayOutput(Constants.modelName)
        }

        let reading = decode(output, characters: characters)
        return reading.text.isEmpty ? nil : reading
    }

    // MARK: - Model / dictionary loading

    private func loadModelIfNeeded() throws -> MLModel {
        if let model { return model }
        let loaded = try CoreMLModelLoader.loadModel(named: Constants.modelName, configuration: configuration)
        outputName = loaded.firstMultiArrayOutputName
        model = loaded
        return loaded
    }

    private func loadCharactersIfNeeded() throws -> [String] {
        if let characters { return characters }
        let url = try CoreMLModelLoader.resolveResourceURL(
            named: Constants.dictionaryName,
            extension: Constants.dictionaryExtension
        )
        let contents = try String(contentsOf: url, encoding: .utf8)
        let entries = contents.components(separatedBy: .newlines).filter { $0.isEmpty == false }
        // PP-OCR CTC layout: index 0 is the blank, a trailing space is appended.
        let characters = [""] + entries + [" "]
        self.characters = characters
        return characters
    }

    // MARK: - Pre-processing

    private func makeInput(from image: CGImage) -> MLMultiArray? {
        let targetWidth = Constants.inputWidth
        let targetHeight = Constants.inputHeight
        // Preserve aspect ratio, then zero-pad the remaining width.
        let resizedWidth = max(1, min(targetWidth, Int((CGFloat(targetHeight) * CGFloat(image.width) / CGFloat(image.height)).rounded())))

        let bytesPerPixel = 4
        let bytesPerRow = resizedWidth * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * targetHeight)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &rgba,
                width: resizedWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: resizedWidth, height: targetHeight))

        guard let array = try? MLMultiArray(
            shape: [1, NSNumber(value: Constants.channelCount), NSNumber(value: targetHeight), NSNumber(value: targetWidth)],
            dataType: .float32
        ) else {
            return nil
        }

        let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
        for index in 0..<array.count { pointer[index] = 0 }

        let strideC = array.strides[1].intValue
        let strideH = array.strides[2].intValue
        let strideW = array.strides[3].intValue

        for y in 0..<targetHeight {
            for x in 0..<resizedWidth {
                let pixel = y * bytesPerRow + x * bytesPerPixel
                let red = (Float32(rgba[pixel]) / 255 - 0.5) / 0.5
                let green = (Float32(rgba[pixel + 1]) / 255 - 0.5) / 0.5
                let blue = (Float32(rgba[pixel + 2]) / 255 - 0.5) / 0.5
                pointer[0 * strideC + y * strideH + x * strideW] = red
                pointer[1 * strideC + y * strideH + x * strideW] = green
                pointer[2 * strideC + y * strideH + x * strideW] = blue
            }
        }
        return array
    }

    // MARK: - CTC decoding

    private func decode(_ output: MLMultiArray, characters: [String]) -> Reading {
        guard output.shape.count == 3 else { return Reading(text: "", confidence: 0) }

        let timeSteps = output.shape[1].intValue
        let classCount = output.shape[2].intValue
        let strideT = output.strides[1].intValue
        let strideC = output.strides[2].intValue
        let base = output.dataPointer.bindMemory(to: Float32.self, capacity: output.count)

        var previousIndex = Constants.ctcBlankIndex
        var text = ""
        var confidenceSum: Float = 0
        var emittedCount = 0

        for step in 0..<timeSteps {
            // argmax + softmax probability of the winner in one pass.
            var bestIndex = 0
            var bestScore = -Float.greatestFiniteMagnitude
            var maxScore = -Float.greatestFiniteMagnitude
            for classIndex in 0..<classCount {
                let score = base[step * strideT + classIndex * strideC]
                if score > bestScore {
                    bestScore = score
                    bestIndex = classIndex
                }
                if score > maxScore { maxScore = score }
            }

            defer { previousIndex = bestIndex }
            guard bestIndex != Constants.ctcBlankIndex,
                  bestIndex != previousIndex,
                  bestIndex < characters.count else { continue }

            // Softmax over the class dim for the winning step -> per-char prob.
            var expSum: Float = 0
            for classIndex in 0..<classCount {
                expSum += exp(base[step * strideT + classIndex * strideC] - maxScore)
            }
            let probability = expSum > 0 ? exp(bestScore - maxScore) / expSum : 0

            text += characters[bestIndex]
            confidenceSum += probability
            emittedCount += 1
        }

        let confidence = emittedCount > 0 ? confidenceSum / Float(emittedCount) : 0
        return Reading(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: confidence
        )
    }
}
