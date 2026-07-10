import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

/// The asynchronous half of the "tracking-by-detection" design. It owns a single
/// serial queue on which the (expensive) hierarchical CoreML pipeline runs,
/// completely decoupled from the 30 FPS render/tracking loop.
///
/// Back-pressure is handled by *dropping stale work* rather than queuing it:
/// - Only the most recent full-frame is ever kept for vehicle detection, so the
///   detector always works on the freshest frame and its effective rate self-
///   limits to whatever the NPU sustains (~10–20 FPS).
/// - Plate OCR jobs are coalesced per `Vehicle_ID` (latest rect wins).
///
/// Results are delivered on `callbackQueue` (the engine's tracking queue) so all
/// tracker mutations remain serialised.
final class AsyncDetectionCoordinator {
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let orientation: CGImagePropertyOrientation
        let timestamp: CMTime
        var imageSize: CGSize { VisionGeometry.orientedImageSize(of: pixelBuffer, orientation: orientation) }
    }

    var onVehiclesDetected: (([VehicleDetection], CGSize, CMTime) -> Void)?
    var onPlateResolved: ((PlateResolution?, UUID, CMTime) -> Void)?
    var onError: ((Error) -> Void)?

    private let pipeline: HierarchicalDetectionPipeline
    private let callbackQueue: DispatchQueue
    private let workQueue = DispatchQueue(label: "com.poccv.tracking.detector", qos: .userInitiated)

    private let lock = NSLock()
    private var isBusy = false
    private var pendingFrame: Frame?
    private var pendingPlateJobs: [UUID: (rect: CGRect, frame: Frame)] = [:]
    private var plateJobOrder: [UUID] = []
    private var lastWorkWasDetection = false

    init(
        pipeline: HierarchicalDetectionPipeline = HierarchicalDetectionPipeline(),
        callbackQueue: DispatchQueue
    ) {
        self.pipeline = pipeline
        self.callbackQueue = callbackQueue
    }

    // MARK: - Submission (called from the tracking queue)

    /// Offers a frame for vehicle detection. If the detector is busy the frame
    /// simply replaces any previously pending one.
    func submitDetection(frame: Frame) {
        lock.lock()
        pendingFrame = frame
        lock.unlock()
        drain()
    }

    /// Requests plate location + OCR for a specific tracked vehicle.
    func submitPlateResolution(id: UUID, vehicleRect: CGRect, frame: Frame) {
        lock.lock()
        if pendingPlateJobs[id] == nil { plateJobOrder.append(id) }
        pendingPlateJobs[id] = (rect: vehicleRect, frame: frame)
        lock.unlock()
        drain()
    }

    /// Drops queued plate jobs whose vehicle no longer exists — OCR on a dead
    /// track is wasted work and its result would be discarded anyway.
    func cancelPlateJobs(notIn active: Set<UUID>) {
        lock.lock()
        pendingPlateJobs = pendingPlateJobs.filter { active.contains($0.key) }
        plateJobOrder.removeAll { pendingPlateJobs[$0] == nil }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        pendingFrame = nil
        pendingPlateJobs.removeAll()
        plateJobOrder.removeAll()
        lock.unlock()
    }

    // MARK: - Work scheduling

    private enum Work {
        case detect(Frame)
        case plate(id: UUID, rect: CGRect, frame: Frame)
    }

    private func drain() {
        lock.lock()
        guard isBusy == false, let work = nextWorkLocked() else {
            lock.unlock()
            return
        }
        isBusy = true
        lock.unlock()

        workQueue.async { [weak self] in
            self?.execute(work)
        }
    }

    /// Detection is preferred (fresh vehicle positions keep the tracker honest)
    /// but must not monopolise the queue: the render loop replaces
    /// `pendingFrame` every ~33 ms, so whenever one detection pass takes longer
    /// than a frame interval there is *always* a fresh frame waiting — a strict
    /// detection-first policy then starves plate OCR forever and no plate is
    /// ever read. Alternate instead: after a detection slot, a waiting plate
    /// job gets the next slot.
    private func nextWorkLocked() -> Work? {
        if lastWorkWasDetection, let plateJob = nextPlateJobLocked() {
            lastWorkWasDetection = false
            return plateJob
        }
        if let frame = pendingFrame {
            pendingFrame = nil
            lastWorkWasDetection = true
            return .detect(frame)
        }
        lastWorkWasDetection = false
        return nextPlateJobLocked()
    }

    private func nextPlateJobLocked() -> Work? {
        while let id = plateJobOrder.first {
            plateJobOrder.removeFirst()
            if let job = pendingPlateJobs.removeValue(forKey: id) {
                return .plate(id: id, rect: job.rect, frame: job.frame)
            }
        }
        return nil
    }

    private func execute(_ work: Work) {
        switch work {
        case .detect(let frame):
            do {
                let detections = try pipeline.detectVehicles(in: frame.pixelBuffer, orientation: frame.orientation)
                callbackQueue.async { [weak self] in
                    self?.onVehiclesDetected?(detections, frame.imageSize, frame.timestamp)
                }
            } catch {
                deliver(error)
            }

        case .plate(let id, let rect, let frame):
            do {
                let resolution = try pipeline.resolvePlate(forVehicleRect: rect, in: frame.pixelBuffer, orientation: frame.orientation)
                callbackQueue.async { [weak self] in
                    self?.onPlateResolved?(resolution, id, frame.timestamp)
                }
            } catch {
                callbackQueue.async { [weak self] in
                    self?.onPlateResolved?(nil, id, frame.timestamp)
                }
                deliver(error)
            }
        }

        lock.lock()
        isBusy = false
        lock.unlock()
        drain()
    }

    private func deliver(_ error: Error) {
        callbackQueue.async { [weak self] in
            self?.onError?(error)
        }
    }
}
