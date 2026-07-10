# Asynchronous Tracking-by-Detection

Realtime vehicle + license-plate tracking that stays smooth at **30 FPS** even
though the CoreML detector only sustains **~10–20 FPS**. The gap is bridged by
Apple's Vision object tracker (optical flow), which translates *and scales*
bounding boxes on the frames the detector never sees.

## Two decoupled loops

```
Render / track loop (30 FPS, tracking queue)
  processRenderFrame(image, t)
    ├─ VehicleTracker.track()        optical flow advances every box (t+n)
    ├─ emit VehicleOverlayItem[]     boxes + cached plate labels → UI
    ├─ submit frame to detector      dropped if the NPU is still busy
    └─ submit plate OCR on demand    only when a plate is large enough

Detector loop (async, ~10–20 FPS, detector serial queue)
  results delivered back on the tracking queue
    ├─ VehicleTracker.reconcile()    IoU-match, correct drift, mint Vehicle_IDs
    └─ VehiclePlateStore.store()     cache the sharpest plate reading per ID
```

The detector uses **latest-frame-wins** back-pressure (`AsyncDetectionCoordinator`):
stale frames are discarded rather than queued, so playback never stalls and the
detector always works on the freshest frame.

## Hierarchical (parent → child) pipeline

Plates are never tracked directly — they are an *attribute* of a `Vehicle_ID`.
`HierarchicalDetectionPipeline` runs three CoreML stages:

1. **`VehicleDetector`** — `yolo26n`, 640×640, output `[1,300,6]` (end2end/NMS).
   Finds vehicles in the full frame; each match seeds a `VNTrackObjectRequest`.
2. **`LicensePlateLocator`** — `license_nano_model`, 320×320. Runs on the
   *cropped vehicle* only, so the plate is large relative to the input.
3. **`LicensePlateRecognizer`** — `latin_PP-OCRv5_mobile_rec`, `[1,3,48,320]`
   input, CTC-decoded `[1,40,838]`. Reads a sharp plate crop taken from the
   original full-resolution frame (reverse-mapped from the crop), and the text
   is cached against the `Vehicle_ID` — read once when biggest, reused every
   frame thereafter.

## Files

| File | Role |
|------|------|
| `TrackingEngine.swift` | Facade wiring the two loops; the only type the ViewModel touches. |
| `VehicleTracker.swift` | `VNSequenceRequestHandler` + `VNTrackObjectRequest`; per-frame optical flow, IoU reconcile, ID lifecycle. |
| `AsyncDetectionCoordinator.swift` | Serial detector queue with latest-frame-wins throttling. |
| `HierarchicalDetectionPipeline.swift` | Orchestrates the 3 CoreML stages + crop/reverse-map. |
| `VehicleDetector.swift` / `LicensePlateLocator.swift` / `LicensePlateRecognizer.swift` | The individual CoreML stages. |
| `YOLODetectionParser.swift` | Shared decoder for the `[1,N,6]` YOLO output. |
| `VehiclePlateStore.swift` | Thread-safe `[Vehicle_ID: plate]` attribute store. |
| `TrackingModels.swift` | `VehicleDetection`, `PlateResolution`, `TrackedVehicle`, `VehicleOverlayItem`, `PlateState`. |
| `VisionGeometry.swift` | Image-pixel (top-left) ↔ Vision-normalised (bottom-left) conversions + IoU. |
| `CoreMLModelLoader.swift` | Bundle lookup, compilation and model introspection. |

## Coordinate spaces

Everything downstream of frame capture works in **image space** (top-left
origin, source pixels). Vision's normalised bottom-left space is confined to
`VehicleTracker` via `VisionGeometry`, which prevents flipped/mirrored boxes.

## Threading contract

`VehicleTracker`, `VehiclePlateStore` bookkeeping and all engine state are
touched **only on the engine's `trackingQueue`** — the detector delivers its
results there too. CoreML inference runs on the coordinator's own serial queue.
`VehiclePlateStore` is additionally lock-guarded because the UI reads it while
the detector writes it.

## Notes / tuning

- Thresholds live in each type's private `Constants` (detection confidence,
  association IoU, missed-detection expiry, OCR size gate, detector rate cap).
- `VehicleDetector.Constants.allowedClassIndices` is `nil` (accept all classes).
  Set it to the COCO vehicle ids `[2,3,5,7]` if `yolo26n` is a COCO export.
- `Service/LicensePlateDetector.swift` (the earlier synchronous detect+OCR
  class) is superseded by this module and no longer referenced by `HomeViewModel`.
- New files are picked up automatically — the Xcode target uses a file-system
  synchronized group, so no `.pbxproj` edits are required.
