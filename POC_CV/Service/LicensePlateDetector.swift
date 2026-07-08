import CoreGraphics
import CoreMedia
import CoreML
import Foundation

struct LicensePlateInfo {
    let text: String?
    let confidence: Float
    let rect: CGRect
    let timestamp: CMTime
}

final class LicensePlateDetector {
    typealias Completion = (Result<[LicensePlateInfo], Error>) -> Void

    private enum Constants {
        static let detectorModelName = "vietnam_car_nano_model"
        static let recognizerModelName = "latin_PP-OCRv5_mobile_rec"
        static let dictionaryName = "ppocrv5_latin_dict"
        static let dictionaryExtension = "txt"
        static let modelExtension = "mlmodelc"
        static let packageExtension = "mlpackage"
        static let modelSubdirectory = "Assets/coreml"
        static let assetSubdirectory = "Assets"
        static let detectorInputName = "image"
        static let detectorOutputName = "var_1440"
        static let recognizerInputName = "x"
        static let recognizerOutputName = "var_1677"
        static let detectorInputSize = 640
        static let recognizerInputWidth = 320
        static let recognizerInputHeight = 48
        static let recognizerChannelCount = 3
        static let ctcBlankIndex = 0
        static let confidenceThreshold: Float = 0.35
        static let maxDetections = 20
    }

    private let inferenceQueue = DispatchQueue(label: "com.poccv.license-plate.detector", qos: .userInitiated)
    private let stateLock = NSLock()
    private let configuration: MLModelConfiguration
    private var detectorModel: MLModel?
    private var recognizerModel: MLModel?
    private var recognizerCharacters: [String]?
    private var isProcessing = false

    init() {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        self.configuration = configuration
    }

    func detectLicensePlates(in frame: HomeVideoFrame, completion: @escaping Completion) {
        stateLock.lock()
        guard isProcessing == false else {
            stateLock.unlock()
            completion(.success([]))
            return
        }
        isProcessing = true
        stateLock.unlock()

        inferenceQueue.async { [weak self] in
            guard let self else { return }
            defer { self.finishProcessing() }

            do {
                let detections = try self.detectLicensePlates(in: frame)
                completion(.success(detections))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func detectLicensePlates(in frame: HomeVideoFrame) throws -> [LicensePlateInfo] {
        let model = try loadDetectorModelIfNeeded()
        let inputValue = try MLFeatureValue(
            cgImage: frame.cgImage,
            pixelsWide: Constants.detectorInputSize,
            pixelsHigh: Constants.detectorInputSize,
            pixelFormatType: kCVPixelFormatType_32ARGB,
            options: nil
        )

        guard let pixelBuffer = inputValue.imageBufferValue else {
            throw DetectorError.invalidInputImage
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            Constants.detectorInputName: MLFeatureValue(pixelBuffer: pixelBuffer)
        ])
        let output = try model.prediction(from: input)

        guard let multiArray = output.featureValue(for: Constants.detectorOutputName)?.multiArrayValue else {
            throw DetectorError.missingOutput(Constants.detectorOutputName)
        }

        let detections = parseDetections(
            from: multiArray,
            frame: frame,
            imageWidth: CGFloat(frame.cgImage.width),
            imageHeight: CGFloat(frame.cgImage.height)
        )

        return try detections.map { detection in
            let text = try recognizeText(in: detection.rect, from: frame.cgImage)
            return LicensePlateInfo(
                text: text,
                confidence: detection.confidence,
                rect: detection.rect,
                timestamp: detection.timestamp
            )
        }
    }

    private func loadDetectorModelIfNeeded() throws -> MLModel {
        if let detectorModel {
            return detectorModel
        }

        let modelURL = try resolveModelURL(named: Constants.detectorModelName)
        let loadedModel = try loadModel(from: modelURL)
        detectorModel = loadedModel
        return loadedModel
    }

    private func loadRecognizerModelIfNeeded() throws -> MLModel {
        if let recognizerModel {
            return recognizerModel
        }

        let modelURL = try resolveModelURL(named: Constants.recognizerModelName)
        let loadedModel = try loadModel(from: modelURL)
        recognizerModel = loadedModel
        return loadedModel
    }

    private func loadModel(from modelURL: URL) throws -> MLModel {
        let loadURL: URL
        if modelURL.pathExtension == Constants.packageExtension {
            loadURL = try MLModel.compileModel(at: modelURL)
        } else {
            loadURL = modelURL
        }

        return try MLModel(contentsOf: loadURL, configuration: configuration)
    }

    private func loadRecognizerCharactersIfNeeded() throws -> [String] {
        if let recognizerCharacters {
            return recognizerCharacters
        }

        let dictionaryURL = try resolveDictionaryURL()
        let dictionary = try String(contentsOf: dictionaryURL, encoding: .utf8)
        let characters = dictionary
            .components(separatedBy: .newlines)
            .filter { $0.isEmpty == false }
        let recognizerCharacters = [""] + characters + [" "]
        self.recognizerCharacters = recognizerCharacters
        return recognizerCharacters
    }

    private func recognizeText(in rect: CGRect, from image: CGImage) throws -> String? {
        let recognizerModel = try loadRecognizerModelIfNeeded()
        let characters = try loadRecognizerCharactersIfNeeded()

        guard let inputArray = makeRecognizerInput(rect: rect, image: image) else {
            return nil
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            Constants.recognizerInputName: MLFeatureValue(multiArray: inputArray)
        ])
        let output = try recognizerModel.prediction(from: input)

        guard let multiArray = output.featureValue(for: Constants.recognizerOutputName)?.multiArrayValue else {
            throw DetectorError.missingOutput(Constants.recognizerOutputName)
        }

        let text = decodeRecognizerOutput(multiArray, characters: characters)
        return text.isEmpty ? nil : text
    }

    private func makeRecognizerInput(rect: CGRect, image: CGImage) -> MLMultiArray? {
        let imageRect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        let cropRect = rect.integral.intersection(imageRect)
        guard cropRect.isNull == false,
              cropRect.width > 1,
              cropRect.height > 1,
              let croppedImage = image.cropping(to: cropRect) else {
            return nil
        }

        let targetHeight = Constants.recognizerInputHeight
        let targetWidth = Constants.recognizerInputWidth
        let resizedWidth = max(1, min(targetWidth, Int((CGFloat(targetHeight) * cropRect.width / cropRect.height).rounded())))
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
        context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: resizedWidth, height: targetHeight))

        guard let inputArray = try? MLMultiArray(
            shape: [
                1,
                NSNumber(value: Constants.recognizerChannelCount),
                NSNumber(value: targetHeight),
                NSNumber(value: targetWidth)
            ],
            dataType: .float32
        ) else {
            return nil
        }

        let pointer = inputArray.dataPointer.bindMemory(to: Float32.self, capacity: inputArray.count)
        for index in 0..<inputArray.count {
            pointer[index] = 0
        }

        for y in 0..<targetHeight {
            for x in 0..<resizedWidth {
                let pixelOffset = y * bytesPerRow + x * bytesPerPixel
                let red = Float32(rgba[pixelOffset])
                let green = Float32(rgba[pixelOffset + 1])
                let blue = Float32(rgba[pixelOffset + 2])
                writeRecognizerValue((red / 255 - 0.5) / 0.5, channel: 0, y: y, x: x, array: inputArray, pointer: pointer)
                writeRecognizerValue((green / 255 - 0.5) / 0.5, channel: 1, y: y, x: x, array: inputArray, pointer: pointer)
                writeRecognizerValue((blue / 255 - 0.5) / 0.5, channel: 2, y: y, x: x, array: inputArray, pointer: pointer)
            }
        }

        return inputArray
    }

    private func writeRecognizerValue(
        _ value: Float32,
        channel: Int,
        y: Int,
        x: Int,
        array: MLMultiArray,
        pointer: UnsafeMutablePointer<Float32>
    ) {
        let offset = array.strides[0].intValue * 0
            + array.strides[1].intValue * channel
            + array.strides[2].intValue * y
            + array.strides[3].intValue * x
        pointer[offset] = value
    }

    private func decodeRecognizerOutput(_ output: MLMultiArray, characters: [String]) -> String {
        guard output.shape.count == 3 else {
            return ""
        }

        let timeSteps = output.shape[1].intValue
        let classCount = output.shape[2].intValue
        var previousIndex = Constants.ctcBlankIndex
        var text = ""

        for step in 0..<timeSteps {
            var bestIndex = Constants.ctcBlankIndex
            var bestScore = -Float.greatestFiniteMagnitude

            for classIndex in 0..<classCount {
                let score = recognizerValue(timeStep: step, classIndex: classIndex, in: output)
                if score > bestScore {
                    bestScore = score
                    bestIndex = classIndex
                }
            }

            defer { previousIndex = bestIndex }
            guard bestIndex != Constants.ctcBlankIndex, bestIndex != previousIndex else {
                continue
            }
            guard bestIndex < characters.count else {
                continue
            }

            text += characters[bestIndex]
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recognizerValue(timeStep: Int, classIndex: Int, in output: MLMultiArray) -> Float {
        let offset = output.strides[0].intValue * 0
            + output.strides[1].intValue * timeStep
            + output.strides[2].intValue * classIndex
        return output[offset].floatValue
    }

    private func resolveModelURL(named modelName: String) throws -> URL {
        let candidates = [
            Bundle.main.url(forResource: modelName, withExtension: Constants.modelExtension),
            Bundle.main.url(forResource: modelName, withExtension: Constants.modelExtension, subdirectory: Constants.modelSubdirectory),
            Bundle.main.url(forResource: modelName, withExtension: Constants.packageExtension),
            Bundle.main.url(forResource: modelName, withExtension: Constants.packageExtension, subdirectory: Constants.modelSubdirectory)
        ]

        if let url = candidates.compactMap({ $0 }).first {
            return url
        }

        throw DetectorError.modelNotFound(modelName)
    }

    private func resolveDictionaryURL() throws -> URL {
        let candidates = [
            Bundle.main.url(forResource: Constants.dictionaryName, withExtension: Constants.dictionaryExtension),
            Bundle.main.url(forResource: Constants.dictionaryName, withExtension: Constants.dictionaryExtension, subdirectory: Constants.assetSubdirectory),
            Bundle.main.resourceURL?.appendingPathComponent("\(Constants.dictionaryName).\(Constants.dictionaryExtension)"),
            Bundle.main.resourceURL?.appendingPathComponent(Constants.assetSubdirectory).appendingPathComponent("\(Constants.dictionaryName).\(Constants.dictionaryExtension)")
        ]

        if let url = candidates.compactMap({ $0 }).first {
            return url
        }

        throw DetectorError.dictionaryNotFound(Constants.dictionaryName)
    }

    private func parseDetections(
        from output: MLMultiArray,
        frame: HomeVideoFrame,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> [LicensePlateInfo] {
        guard output.shape.count == 3, output.shape[2].intValue >= 5 else {
            return []
        }

        let rowCount = output.shape[1].intValue
        let columnCount = output.shape[2].intValue
        let isNormalized = outputLooksNormalized(output, rowCount: rowCount, columnCount: columnCount)
        let scaleX = isNormalized ? imageWidth : imageWidth / CGFloat(Constants.detectorInputSize)
        let scaleY = isNormalized ? imageHeight : imageHeight / CGFloat(Constants.detectorInputSize)

        var results: [LicensePlateInfo] = []
        results.reserveCapacity(min(rowCount, Constants.maxDetections))

        for row in 0..<rowCount {
            let confidence = value(at: row, column: 4, in: output)
            guard confidence >= Constants.confidenceThreshold else { continue }

            let x1 = CGFloat(value(at: row, column: 0, in: output))
            let y1 = CGFloat(value(at: row, column: 1, in: output))
            let x2 = CGFloat(value(at: row, column: 2, in: output))
            let y2 = CGFloat(value(at: row, column: 3, in: output))
            let rect = makeRect(
                x1: x1,
                y1: y1,
                x2: x2,
                y2: y2,
                scaleX: scaleX,
                scaleY: scaleY,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )

            guard rect.isNull == false, rect.width > 1, rect.height > 1 else { continue }

            results.append(LicensePlateInfo(
                text: nil,
                confidence: confidence,
                rect: rect,
                timestamp: frame.timestamp
            ))
        }

        return results
            .sorted { $0.confidence > $1.confidence }
            .prefix(Constants.maxDetections)
            .map { $0 }
    }

    private func outputLooksNormalized(_ output: MLMultiArray, rowCount: Int, columnCount: Int) -> Bool {
        let inspectedRows = rowCount
        guard inspectedRows > 0, columnCount >= 4 else { return false }

        var maxCoordinate: Float = 0
        for row in 0..<inspectedRows {
            for column in 0..<4 {
                maxCoordinate = max(maxCoordinate, abs(value(at: row, column: column, in: output)))
            }
        }

        return maxCoordinate <= 1.5
    }

    private func value(at row: Int, column: Int, in output: MLMultiArray) -> Float {
        let offset = output.strides[0].intValue * 0
            + output.strides[1].intValue * row
            + output.strides[2].intValue * column
        return output[offset].floatValue
    }

    private func makeRect(
        x1: CGFloat,
        y1: CGFloat,
        x2: CGFloat,
        y2: CGFloat,
        scaleX: CGFloat,
        scaleY: CGFloat,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> CGRect {
        let rawRect: CGRect
        if x2 > x1, y2 > y1 {
            rawRect = CGRect(x: x1 * scaleX, y: y1 * scaleY, width: (x2 - x1) * scaleX, height: (y2 - y1) * scaleY)
        } else {
            rawRect = CGRect(x: (x1 - x2 / 2) * scaleX, y: (y1 - y2 / 2) * scaleY, width: x2 * scaleX, height: y2 * scaleY)
        }

        let imageRect = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let clippedRect = rawRect.integral.intersection(imageRect)
        return clippedRect.isNull ? .null : clippedRect
    }

    private func finishProcessing() {
        stateLock.lock()
        isProcessing = false
        stateLock.unlock()
    }
}

private enum DetectorError: LocalizedError {
    case modelNotFound(String)
    case dictionaryNotFound(String)
    case invalidInputImage
    case missingOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let modelName):
            return "Unable to find CoreML model \(modelName)."
        case .dictionaryNotFound(let dictionaryName):
            return "Unable to find OCR dictionary \(dictionaryName)."
        case .invalidInputImage:
            return "Unable to create detector input image."
        case .missingOutput(let outputName):
            return "Unable to read detector output \(outputName)."
        }
    }
}
