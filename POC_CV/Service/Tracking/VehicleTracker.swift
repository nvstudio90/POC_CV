import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Vision

/// The lightweight, per-frame tracker that runs at the full 30 FPS render rate.
///
/// It uses Apple's built-in object tracker (`VNTrackObjectRequest` driven by a
/// `VNSequenceRequestHandler`), which follows image-point features via optical
/// flow and automatically translates *and scales* each bounding box — so a
/// vehicle box grows smoothly as the vehicle approaches, even on frames the YOLO
/// detector never sees (`t + n`).
///
/// The slower detector thread calls `reconcile(...)` to correct drift and to
/// issue new `Vehicle_ID`s. Every method must be invoked on a single serial
/// queue (owned by `TrackingEngine`); the class holds no internal locks.
final class VehicleTracker {
    private enum Constants {
        /// Below this Vision tracking confidence a track is considered lost.
        static let minTrackingConfidence: Float = 0.30
        /// IoU above which a detection is treated as the *same* vehicle.
        static let associationIoU: CGFloat = 0.30
        /// Detector passes a track may survive without a matching detection.
        static let maxMissedDetections = 4
        /// Hard cap on frames tracked by optical flow alone before expiry (~3s).
        static let maxFramesSinceCorrection = 90
    }

    private var vehicles: [UUID: TrackedVehicle] = [:]
    private let sequenceHandler = VNSequenceRequestHandler()

    // MARK: - Per-frame tracking (30 FPS)

    /// Advances every active track by one frame of optical flow and returns the
    /// updated set. Tracks that Vision loses (or that have drifted too long
    /// without a detection correction) are dropped. `pixelBuffer` is the raw,
    /// *unrotated* frame straight from the video output — Vision applies
    /// `orientation` internally, so no `CGImage`/`CIImage` conversion is needed.
    @discardableResult
    func track(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, timestamp: CMTime) -> [TrackedVehicle] {
        guard vehicles.isEmpty == false else { return [] }

        let imageSize = VisionGeometry.orientedImageSize(of: pixelBuffer, orientation: orientation)
        let requests: [VNRequest] = vehicles.values.map { $0.trackingRequest }

        do {
            try sequenceHandler.perform(requests, on: pixelBuffer, orientation: orientation)
        } catch {
            // A failed sequence pass shouldn't nuke state; keep the last boxes.
            return Array(vehicles.values)
        }

        var expired: [UUID] = []
        for vehicle in vehicles.values {
            guard let observation = vehicle.trackingRequest.results?.first as? VNDetectedObjectObservation else {
                expired.append(vehicle.id)
                continue
            }

            vehicle.framesSinceCorrection += 1

            if observation.confidence < Constants.minTrackingConfidence
                || vehicle.framesSinceCorrection > Constants.maxFramesSinceCorrection {
                expired.append(vehicle.id)
                continue
            }

            vehicle.boundingBox = VisionGeometry.imageRect(
                fromNormalizedRect: observation.boundingBox,
                imageSize: imageSize
            )
            vehicle.confidence = observation.confidence
            vehicle.lastUpdated = timestamp
            // Feed this frame's result back in as next frame's seed.
            vehicle.trackingRequest.inputObservation = observation
        }

        expired.forEach { remove(id: $0) }
        return Array(vehicles.values)
    }

    // MARK: - Detector correction (10–20 FPS)

    struct ReconcileResult {
        /// Vehicles that received a brand-new `Vehicle_ID` this pass.
        let newVehicleIDs: [UUID]
    }

    /// Associates fresh YOLO detections with existing tracks (greedy IoU),
    /// correcting drift on matches and spawning new tracks for unmatched
    /// detections. `detectionImageSize` is the pixel size of the frame the
    /// detections were computed on.
    @discardableResult
    func reconcile(
        detections: [VehicleDetection],
        detectionImageSize: CGSize,
        timestamp: CMTime
    ) -> ReconcileResult {
        var unmatchedVehicleIDs = Set(vehicles.keys)
        var newVehicleIDs: [UUID] = []

        // Greedy match: strongest detections first.
        for detection in detections.sorted(by: { $0.confidence > $1.confidence }) {
            if let match = bestMatch(for: detection.rect, among: unmatchedVehicleIDs) {
                correct(vehicle: match, with: detection, imageSize: detectionImageSize, timestamp: timestamp)
                unmatchedVehicleIDs.remove(match.id)
            } else {
                let vehicle = makeVehicle(from: detection, imageSize: detectionImageSize, timestamp: timestamp)
                vehicles[vehicle.id] = vehicle
                newVehicleIDs.append(vehicle.id)
            }
        }

        // Age out tracks that no detection backed this pass.
        for id in unmatchedVehicleIDs {
            guard let vehicle = vehicles[id] else { continue }
            vehicle.missedDetections += 1
            if vehicle.missedDetections > Constants.maxMissedDetections {
                remove(id: id)
            }
        }

        return ReconcileResult(newVehicleIDs: newVehicleIDs)
    }

    // MARK: - Accessors (tracking queue only)

    func snapshot() -> [TrackedVehicle] { Array(vehicles.values) }

    func activeIDs() -> Set<UUID> { Set(vehicles.keys) }

    func vehicle(for id: UUID) -> TrackedVehicle? { vehicles[id] }

    func setPlateState(_ state: PlateState, for id: UUID) {
        vehicles[id]?.plateState = state
    }

    func reset() {
        for vehicle in vehicles.values {
            vehicle.trackingRequest.isLastFrame = true
        }
        vehicles.removeAll()
    }

    // MARK: - Private

    private func bestMatch(for rect: CGRect, among ids: Set<UUID>) -> TrackedVehicle? {
        var best: TrackedVehicle?
        var bestIoU = Constants.associationIoU
        for id in ids {
            guard let vehicle = vehicles[id] else { continue }
            let iou = VisionGeometry.iou(rect, vehicle.boundingBox)
            if iou >= bestIoU {
                bestIoU = iou
                best = vehicle
            }
        }
        return best
    }

    private func correct(
        vehicle: TrackedVehicle,
        with detection: VehicleDetection,
        imageSize: CGSize,
        timestamp: CMTime
    ) {
        vehicle.boundingBox = detection.rect
        vehicle.confidence = detection.confidence
        vehicle.lastUpdated = timestamp
        vehicle.missedDetections = 0
        vehicle.framesSinceCorrection = 0
        // Re-seed the optical-flow tracker from the authoritative detection box.
        vehicle.trackingRequest = makeRequest(for: detection.rect, imageSize: imageSize)
    }

    private func makeVehicle(
        from detection: VehicleDetection,
        imageSize: CGSize,
        timestamp: CMTime
    ) -> TrackedVehicle {
        TrackedVehicle(
            boundingBox: detection.rect,
            confidence: detection.confidence,
            lastUpdated: timestamp,
            trackingRequest: makeRequest(for: detection.rect, imageSize: imageSize)
        )
    }

    private func makeRequest(for imageRect: CGRect, imageSize: CGSize) -> VNTrackObjectRequest {
        let normalized = VisionGeometry.normalizedRect(fromImageRect: imageRect, imageSize: imageSize)
        let observation = VNDetectedObjectObservation(boundingBox: normalized)
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate
        return request
    }

    private func remove(id: UUID) {
        vehicles[id]?.trackingRequest.isLastFrame = true
        vehicles[id] = nil
    }
}
