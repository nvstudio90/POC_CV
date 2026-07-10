import CoreGraphics
import Foundation

/// Coordinates the parent→child detection cascade described in the architecture:
///
/// 1. `VehicleDetector` (yolo26n @ 640) finds vehicles in the full frame.
/// 2. For a given vehicle, `LicensePlateLocator` (license_nano @ 320) finds the
///    plate *inside the cropped vehicle* — plates are never tracked directly.
/// 3. The plate rect is mapped back onto the full-resolution source frame, a
///    sharp plate crop is taken and `LicensePlateRecognizer` (OCR) reads it.
///
/// Every method here is synchronous and must be called on the detector queue.
final class HierarchicalDetectionPipeline {
    private enum Constants {
        /// Padding applied around a vehicle box before plate location, so plates
        /// near the vehicle edge are not clipped.
        static let vehiclePadding: CGFloat = 0.04
        /// Padding applied around the located plate before OCR.
        static let platePadding: CGFloat = 0.08
        static let minPlateSize: CGFloat = 8
    }

    private let vehicleDetector: VehicleDetector
    private let plateLocator: LicensePlateLocator
    private let plateRecognizer: LicensePlateRecognizer

    init(
        vehicleDetector: VehicleDetector = VehicleDetector(),
        plateLocator: LicensePlateLocator = LicensePlateLocator(),
        plateRecognizer: LicensePlateRecognizer = LicensePlateRecognizer()
    ) {
        self.vehicleDetector = vehicleDetector
        self.plateLocator = plateLocator
        self.plateRecognizer = plateRecognizer
    }

    /// Stage 1 — full-frame vehicle detection.
    func detectVehicles(in image: CGImage) throws -> [VehicleDetection] {
        try vehicleDetector.detectVehicles(in: image)
    }

    /// Stages 2 + 3 — locate the plate within a vehicle region and OCR it.
    /// `vehicleRect` is in `image` space (top-left origin, pixels).
    func resolvePlate(forVehicleRect vehicleRect: CGRect, in image: CGImage) throws -> PlateResolution? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let vehicleCropRect = vehicleRect.expanded(by: Constants.vehiclePadding, within: bounds).integral
        guard vehicleCropRect.width > Constants.minPlateSize,
              vehicleCropRect.height > Constants.minPlateSize,
              let vehicleCrop = image.cropping(to: vehicleCropRect) else {
            return nil
        }

        // Stage 2: plate rect in the vehicle-crop's own pixel space.
        guard let plate = try plateLocator.locatePlate(in: vehicleCrop) else { return nil }

        // Reverse-map: crop space -> full-frame space (crop taken at native res,
        // so this is a pure translation by the crop origin).
        let plateRectInFrame = CGRect(
            x: vehicleCropRect.minX + plate.rect.minX,
            y: vehicleCropRect.minY + plate.rect.minY,
            width: plate.rect.width,
            height: plate.rect.height
        )

        // Stage 3: take a sharp plate crop from the *original* full-res frame.
        let plateCropRect = plateRectInFrame.expanded(by: Constants.platePadding, within: bounds).integral
        guard plateCropRect.width > Constants.minPlateSize,
              plateCropRect.height > Constants.minPlateSize,
              let plateCrop = image.cropping(to: plateCropRect),
              let reading = try plateRecognizer.recognize(plateImage: plateCrop) else {
            return nil
        }

        return PlateResolution(
            rect: plateRectInFrame,
            text: reading.text,
            confidence: reading.confidence,
            sourceHeight: plateRectInFrame.height
        )
    }
}
