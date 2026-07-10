import CoreGraphics
import CoreMedia
import Foundation
import Vision

/// A raw vehicle detection produced by the CoreML YOLO stage.
/// `rect` is in image space (top-left origin, pixels of the source frame).
struct VehicleDetection {
    let rect: CGRect
    let confidence: Float
    let classIndex: Int
}

/// Result of the plate sub-pipeline (locator + OCR) for a single vehicle crop.
struct PlateResolution {
    /// Plate rectangle mapped back into the full-frame image space.
    let rect: CGRect
    let text: String
    let confidence: Float
    /// Plate height in source pixels — used to keep only the sharpest reading
    /// (plate grows as the vehicle approaches the camera).
    let sourceHeight: CGFloat
}

/// Lifecycle of the OCR attribute attached to a tracked vehicle.
enum PlateState: Equatable {
    case unknown
    case pending
    case resolved(text: String)
    case failed
}

/// A vehicle currently followed by the Vision tracker. Owned and mutated
/// exclusively on the tracking queue.
final class TrackedVehicle {
    let id: UUID
    /// Current bounding box in image space (top-left origin, pixels).
    var boundingBox: CGRect
    var confidence: Float
    var lastUpdated: CMTime

    /// Live Vision tracking request (carries the optical-flow observation across
    /// frames). Recreated whenever the detector supplies a fresh correction.
    var trackingRequest: VNTrackObjectRequest
    /// Consecutive detector passes in which this track had no matching detection.
    var missedDetections: Int
    /// Total frames tracked purely by optical flow since the last correction.
    var framesSinceCorrection: Int
    var plateState: PlateState

    init(
        id: UUID = UUID(),
        boundingBox: CGRect,
        confidence: Float,
        lastUpdated: CMTime,
        trackingRequest: VNTrackObjectRequest
    ) {
        self.id = id
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.lastUpdated = lastUpdated
        self.trackingRequest = trackingRequest
        self.missedDetections = 0
        self.framesSinceCorrection = 0
        self.plateState = .unknown
    }
}

/// Immutable snapshot handed to the UI layer every render frame (30 FPS).
struct VehicleOverlayItem {
    let id: UUID
    /// Bounding box in image space (top-left origin, pixels of the source frame).
    let rect: CGRect
    let plateText: String?
    let confidence: Float
    /// `true` when the box came from optical-flow tracking rather than a fresh
    /// detection this frame (useful for debug tinting).
    let isPredicted: Bool
}
