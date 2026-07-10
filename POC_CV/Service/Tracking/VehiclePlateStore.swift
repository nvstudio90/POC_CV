import CoreGraphics
import CoreMedia
import Foundation

/// Thread-safe attribute store mapping a `Vehicle_ID` (issued by the Vision
/// tracker) to its recognised license-plate text — the `[UUID: String]`
/// dictionary from the spec, plus enough metadata to keep only the best reading.
///
/// Written from the detector queue (new OCR results) and read from the tracking
/// queue every render frame, hence the lock.
final class VehiclePlateStore {
    struct Record {
        var text: String
        var confidence: Float
        /// Plate height in source pixels when this reading was captured. A plate
        /// only grows as the vehicle approaches, so a taller reading is sharper.
        var sourceHeight: CGFloat
        var updatedAt: CMTime
    }

    private let lock = NSLock()
    private var storage: [UUID: Record] = [:]

    /// Convenience accessor for the render loop.
    func text(for id: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[id]?.text
    }

    func record(for id: UUID) -> Record? {
        lock.lock(); defer { lock.unlock() }
        return storage[id]
    }

    /// Stores a reading, overwriting an existing one only when the new plate is
    /// larger (sharper) or clearly more confident. This makes the label "lock
    /// in" once read at close range and stop flickering.
    /// - Returns: `true` if the record was written.
    @discardableResult
    func store(_ resolution: PlateResolution, for id: UUID, at time: CMTime) -> Bool {
        lock.lock(); defer { lock.unlock() }

        if let existing = storage[id] {
            let sharperPlate = resolution.sourceHeight > existing.sourceHeight * 1.15
            let moreConfident = resolution.confidence > existing.confidence + 0.1
            guard sharperPlate || moreConfident else { return false }
        }

        storage[id] = Record(
            text: resolution.text,
            confidence: resolution.confidence,
            sourceHeight: resolution.sourceHeight,
            updatedAt: time
        )
        return true
    }

    func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        storage[id] = nil
    }

    /// Drops records for vehicles no longer being tracked.
    func retain(ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        storage = storage.filter { ids.contains($0.key) }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
