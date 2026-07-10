import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import QuartzCore

/// Facade that fuses the fast Vision tracker (30 FPS) with the slow asynchronous
/// CoreML detector, exposing a tiny surface to the presentation layer.
///
/// Threading model — everything that touches the tracker or the per-vehicle
/// bookkeeping runs on a single serial `trackingQueue`:
///
/// ```
/// render tick (30 FPS) ─► processRenderFrame ─► [trackingQueue]
/// │                                              ├─ tracker.track()            (optical flow)
/// │                                              ├─ build + emit overlay        (reads plate store)
/// │                                              ├─ submit frame to detector    (dropped if busy)
/// │                                              └─ submit plate OCR on demand
/// detector queue (async, ~10–20 FPS) ─► results ─► [trackingQueue]
///                                                ├─ tracker.reconcile()         (correct + new IDs)
///                                                └─ plate store update
/// ```
final class TrackingEngine {
    /// Emitted every render frame with the boxes+labels to draw. Delivered on
    /// `trackingQueue`; the presentation layer should hop to main.
    var onOverlayItems: (([VehicleOverlayItem]) -> Void)?
    var onError: ((Error) -> Void)?

    private enum Constants {
        /// Don't OCR until the vehicle box is at least this tall (fraction of the
        /// frame height) — small/distant plates are unreadable and waste battery.
        static let minVehicleHeightFraction: CGFloat = 0.10
        static let minVehicleHeightPixels: CGFloat = 64
        /// Re-read a plate once the vehicle has grown this much since last OCR.
        static let reocrGrowthFactor: CGFloat = 1.4
        /// Minimum spacing between vehicle-detection submissions (battery cap).
        static let detectionMinInterval: CFTimeInterval = 1.0 / 30.0
        /// Render frames admitted onto `trackingQueue` but not yet processed.
        /// Each enqueued frame retains a full pixel buffer, so when optical-flow
        /// tracking runs slower than the render cadence the backlog must be
        /// bounded — excess frames are dropped, never queued.
        static let maxQueuedRenderFrames = 2
    }

    private let trackingQueue = DispatchQueue(label: "com.poccv.tracking.engine", qos: .userInitiated)
    private let tracker = VehicleTracker()
    private let plateStore = VehiclePlateStore()
    private let coordinator: AsyncDetectionCoordinator

    private var pendingOCR: Set<UUID> = []
    private var lastOCRHeight: [UUID: CGFloat] = [:]
    private var lastDetectionSubmit: CFTimeInterval = 0

    /// Guards `queuedRenderFrames` — touched from the render tick (state queue)
    /// and from `trackingQueue`.
    private let queueDepthLock = NSLock()
    private var queuedRenderFrames = 0

    init() {
        coordinator = AsyncDetectionCoordinator(callbackQueue: trackingQueue)
        coordinator.onVehiclesDetected = { [weak self] detections, imageSize, timestamp in
            self?.handleDetections(detections, imageSize: imageSize, timestamp: timestamp)
        }
        coordinator.onPlateResolved = { [weak self] resolution, id, timestamp in
            self?.handlePlateResolution(resolution, for: id, timestamp: timestamp)
        }
        coordinator.onError = { [weak self] error in
            self?.onError?(error)
        }
    }

    // MARK: - Render loop entry point (30 FPS)

    /// Feed one frame from the render loop. `pixelBuffer` is the raw,
    /// *unrotated* buffer straight from the video output; `orientation` tells
    /// Vision/CoreML how to interpret it upright. No `CGImage` conversion
    /// happens here — that only happens deep inside the async detector path,
    /// and only at its own throttled cadence.
    func processRenderFrame(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, timestamp: CMTime) {
        // Back-pressure: if tracking is already behind, drop the frame *now*
        // instead of enqueuing it — a queued block retains the pixel buffer,
        // and an unbounded backlog of full frames is a memory kill on
        // constrained devices. Optical flow tolerates skipped frames.
        queueDepthLock.lock()
        guard queuedRenderFrames < Constants.maxQueuedRenderFrames else {
            queueDepthLock.unlock()
            return
        }
        queuedRenderFrames += 1
        queueDepthLock.unlock()

        trackingQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.queueDepthLock.lock()
                self.queuedRenderFrames -= 1
                self.queueDepthLock.unlock()
            }

            // 1. Advance optical-flow tracks (handles the missing t+n frames).
            let vehicles = self.tracker.track(in: pixelBuffer, orientation: orientation, timestamp: timestamp)

            // 2. Emit overlay immediately so the UI never stalls on detection.
            self.emitOverlay(for: vehicles)

            let frame = AsyncDetectionCoordinator.Frame(pixelBuffer: pixelBuffer, orientation: orientation, timestamp: timestamp)

            // 3. Keep the detector fed with the freshest frame (self-throttling).
            let now = CACurrentMediaTime()
            if now - self.lastDetectionSubmit >= Constants.detectionMinInterval {
                self.lastDetectionSubmit = now
                self.coordinator.submitDetection(frame: frame)
            }

            // 4. Lazily OCR plates that are now large enough.
            self.scheduleOCRIfNeeded(for: vehicles, frame: frame, imageHeight: frame.imageSize.height)
        }
    }

    func reset() {
        trackingQueue.async { [weak self] in
            guard let self else { return }
            self.tracker.reset()
            self.plateStore.removeAll()
            self.coordinator.reset()
            self.pendingOCR.removeAll()
            self.lastOCRHeight.removeAll()
            self.lastDetectionSubmit = 0
            self.emitOverlay(for: [])
        }
    }

    // MARK: - Detector callbacks (trackingQueue)

    private func handleDetections(_ detections: [VehicleDetection], imageSize: CGSize, timestamp: CMTime) {
        tracker.reconcile(detections: detections, detectionImageSize: imageSize, timestamp: timestamp)
        // Drop bookkeeping for vehicles that no longer exist.
        let active = tracker.activeIDs()
        plateStore.retain(ids: active)
        pendingOCR.formIntersection(active)
        lastOCRHeight = lastOCRHeight.filter { active.contains($0.key) }
        coordinator.cancelPlateJobs(notIn: active)
    }

    private func handlePlateResolution(_ resolution: PlateResolution?, for id: UUID, timestamp: CMTime) {
        pendingOCR.remove(id)

        guard let resolution, resolution.text.isEmpty == false else {
            // Allow a later retry (e.g. once the plate is bigger/sharper).
            if tracker.vehicle(for: id)?.plateState == .pending {
                tracker.setPlateState(.failed, for: id)
            }
            return
        }

        // Note: `lastOCRHeight` is recorded at submit time (vehicle-box height).
        // `resolution.sourceHeight` is the *plate* height — comparing that with
        // vehicle heights made `grewEnough` always true and re-OCR'd endlessly.
        plateStore.store(resolution, for: id, at: timestamp)
        // Always surface the *best* stored reading (may be an earlier, sharper one).
        if let best = plateStore.record(for: id) {
            tracker.setPlateState(.resolved(text: best.text), for: id)
        }
    }

    // MARK: - OCR scheduling (trackingQueue)

    private func scheduleOCRIfNeeded(for vehicles: [TrackedVehicle], frame: AsyncDetectionCoordinator.Frame, imageHeight: CGFloat) {
        let minHeight = max(Constants.minVehicleHeightPixels, imageHeight * Constants.minVehicleHeightFraction)

        for vehicle in vehicles {
            guard vehicle.boundingBox.height >= minHeight else { continue }
            guard pendingOCR.contains(vehicle.id) == false else { continue }

            let grewEnough: Bool
            if let previous = lastOCRHeight[vehicle.id] {
                grewEnough = vehicle.boundingBox.height > previous * Constants.reocrGrowthFactor
            } else {
                grewEnough = true
            }

            let needsRead: Bool
            switch vehicle.plateState {
            case .resolved, .failed:
                // Retry/upgrade only once the vehicle is meaningfully closer —
                // retrying a failed read every frame floods the OCR queue,
                // which delays detection passes and destabilises the tracker.
                needsRead = grewEnough
            case .unknown:
                needsRead = true
            case .pending:
                needsRead = false
            }
            guard needsRead else { continue }

            pendingOCR.insert(vehicle.id)
            // Record the vehicle height this attempt was made at, so the next
            // attempt requires real growth (applies to failures too).
            lastOCRHeight[vehicle.id] = vehicle.boundingBox.height
            if case .unknown = vehicle.plateState {
                tracker.setPlateState(.pending, for: vehicle.id)
            }
            coordinator.submitPlateResolution(id: vehicle.id, vehicleRect: vehicle.boundingBox, frame: frame)
        }
    }

    // MARK: - Overlay

    private func emitOverlay(for vehicles: [TrackedVehicle]) {
        // Only surface vehicles whose license plate has actually been read.
        let items = vehicles.compactMap { vehicle -> VehicleOverlayItem? in
            guard let plateText = plateStore.text(for: vehicle.id), plateText.isEmpty == false else {
                return nil
            }
            guard let pt = PlateValidator.cleanAndValidatePlate(rawText: plateText) else {
                return nil
            }
            return VehicleOverlayItem(
                id: vehicle.id,
                rect: vehicle.boundingBox,
                plateText: pt,
                confidence: vehicle.confidence,
                isPredicted: vehicle.framesSinceCorrection > 0
            )
        }
        onOverlayItems?(items)
    }
}
