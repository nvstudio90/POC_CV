import AVFoundation
import CoreImage
import Foundation

struct HomeVideoFrame {
    let cgImage: CGImage
    let size: CGSize
    let timestamp: CMTime
}

enum HomePlaybackState {
    case idle
    case loading
    case playing
    case paused
    case completed
    case failed(String)
}

protocol HomeViewModelProtocol: AnyObject {
    var title: String { get }
    var onFrameReady: ((HomeVideoFrame) -> Void)? { get set }
    var onLicensePlatesDetected: (([LicensePlateInfo]) -> Void)? { get set }
    var onStatusChanged: ((String) -> Void)? { get set }
    var onPlaybackStateChanged: ((HomePlaybackState) -> Void)? { get set }
    var onFPSChanged: ((Int) -> Void)? { get set }
    var onTimelineChanged: ((Double, Double) -> Void)? { get set }

    func startStreaming()
    func stopStreaming()
    func play()
    func pause()
    func replay()
    func updateFPS(_ fps: Int)
    func seek(to progress: Float)
    func setVideoURL(_ url: URL)
}

final class HomeViewModel: HomeViewModelProtocol {
    let title = "Home"

    var onFrameReady: ((HomeVideoFrame) -> Void)?
    var onLicensePlatesDetected: (([LicensePlateInfo]) -> Void)?
    var onStatusChanged: ((String) -> Void)?
    var onPlaybackStateChanged: ((HomePlaybackState) -> Void)?
    var onFPSChanged: ((Int) -> Void)?
    var onTimelineChanged: ((Double, Double) -> Void)?

    private let stateQueue = DispatchQueue(label: "com.poccv.home.video.state", qos: .userInitiated)
    private let decodeQueue = DispatchQueue(label: "com.poccv.home.video.decode", qos: .userInitiated)
    private let licensePlateDetector = LicensePlateDetector()
    private let ciContext = CIContext()
    private let defaultFPS = 30
    private let minFPS = 1
    private let maxFPS = 60
    private let targetBufferSize = 18
    private let refillThreshold = 6
    private let seekTolerance = CMTime(seconds: 0.05, preferredTimescale: 600)

    private var videoURL: URL?
    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var displaySize = CGSize.zero
    private var preferredTransform = CGAffineTransform.identity
    private var duration = CMTime.zero

    private var playbackTimer: DispatchSourceTimer?
    private var currentFPS = 12
    private var playbackState: HomePlaybackState = .idle
    private var isStopped = false
    private var hasPreparedVideo = false
    private var generation = 0
    private var isDecodeInFlight = false
    private var isPlateDetectionInFlight = false
    private var lastPlateDetectionTime = CMTime.negativeInfinity
    private let plateDetectionInterval = CMTime(seconds: 0.15, preferredTimescale: 600)

    private var assetReader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var frameBuffer: [HomeVideoFrame] = []
    private var lastRenderedFrame: HomeVideoFrame?
    private var currentTime = CMTime.zero
    private var playbackStartTime = CMTime.zero
    private var reachedEndOfVideo = false

    init() {
        currentFPS = defaultFPS
    }

    func setVideoURL(_ url: URL) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.videoURL = url
            self.asset = nil
            self.videoTrack = nil
            self.duration = .zero
            self.displaySize = .zero
            self.preferredTransform = .identity
            self.hasPreparedVideo = false
            self.generation += 1
            self.isDecodeInFlight = false
            self.isPlateDetectionInFlight = false
            self.lastPlateDetectionTime = .negativeInfinity
            self.isStopped = false
            self.stopTimerLocked()
            self.cancelReaderLocked()
            self.frameBuffer.removeAll(keepingCapacity: true)
            self.lastRenderedFrame = nil
            self.currentTime = .zero
            self.playbackStartTime = .zero
            self.reachedEndOfVideo = false
            self.emitLicensePlates([])
            self.emitTimeline(current: 0, duration: 0)
            self.setPlaybackState(.idle)
            self.notifyStatus("Video source updated.")
        }
    }

    func startStreaming() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.isStopped = false
            self.emitFPS(self.currentFPS)

            if self.hasPreparedVideo {
                self.playLocked()
                return
            }

            self.setPlaybackState(.loading)
            self.notifyStatus("Loading bundled video...")
            self.prepareVideoLocked()
        }
    }

    func stopStreaming() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.generation += 1
            self.stopTimerLocked()
            self.cancelReaderLocked()
            self.frameBuffer.removeAll(keepingCapacity: true)
            self.isPlateDetectionInFlight = false
            self.emitLicensePlates([])
            self.setPlaybackState(.paused)
        }
    }

    func play() {
        stateQueue.async { [weak self] in
            self?.playLocked()
        }
    }

    func pause() {
        stateQueue.async { [weak self] in
            self?.pauseLocked()
        }
    }

    func replay() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.isStopped = false
            self.seekLocked(to: .zero, autoplay: true)
        }
    }

    func updateFPS(_ fps: Int) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            let clampedFPS = max(self.minFPS, min(self.maxFPS, fps))
            self.currentFPS = clampedFPS
            self.emitFPS(clampedFPS)

            if case .playing = self.playbackState {
                self.startTimerLocked()
                self.notifyStatus("Playing at \(clampedFPS) FPS.")
            }
        }
    }

    func seek(to progress: Float) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard self.duration.isNumeric, self.duration.seconds > 0 else { return }
            let clampedProgress = max(0, min(1, Double(progress)))
            let seconds = self.duration.seconds * clampedProgress
            let seekTime = CMTime(seconds: seconds, preferredTimescale: 600)
            let shouldAutoplay: Bool
            if case .playing = self.playbackState {
                shouldAutoplay = true
            } else {
                shouldAutoplay = false
            }
            self.seekLocked(to: seekTime, autoplay: shouldAutoplay)
        }
    }

    private func prepareVideoLocked() {
        guard let videoURL else {
            failLocked("Missing video URL. Call setVideoURL(_:) before starting playback.")
            return
        }

        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            failLocked("The provided URL does not contain a video track.")
            return
        }

        self.asset = asset
        self.videoTrack = videoTrack
        duration = asset.duration
        preferredTransform = videoTrack.preferredTransform
        displaySize = displaySize(for: videoTrack)
        hasPreparedVideo = true
        currentTime = .zero
        playbackStartTime = .zero
        emitTimeline(current: 0, duration: duration.seconds)

        seekLocked(to: .zero, autoplay: true)
    }

    private func seekLocked(to time: CMTime, autoplay: Bool) {
        guard hasPreparedVideo else {
            startStreaming()
            return
        }

        generation += 1
        let currentGeneration = generation
        isStopped = false
        stopTimerLocked()
        cancelReaderLocked()
        frameBuffer.removeAll(keepingCapacity: true)
        reachedEndOfVideo = false
        isDecodeInFlight = false
        isPlateDetectionInFlight = false
        lastPlateDetectionTime = .negativeInfinity
        playbackStartTime = normalizedTime(time)
        currentTime = playbackStartTime
        emitLicensePlates([])
        emitTimeline(current: currentTime.seconds, duration: duration.seconds)

        do {
            try createReaderLocked(startingAt: playbackStartTime)
            requestDecodeLocked(generation: currentGeneration, minimumCount: 1)

            if autoplay {
                setPlaybackState(.loading)
                notifyStatus("Seeking and buffering...")
                startTimerLocked()
            } else {
                setPlaybackState(.paused)
                notifyStatus("Seeked to \(formatSeconds(currentTime.seconds)).")
            }
        } catch {
            failLocked(error.localizedDescription)
        }
    }

    private func createReaderLocked(startingAt time: CMTime) throws {
        cancelReaderLocked()

        guard let asset, let videoTrack else {
            throw NSError(domain: "HomeViewModel", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing prepared video asset."
            ])
        }

        let reader = try AVAssetReader(asset: asset)
        if time > .zero {
            reader.timeRange = CMTimeRange(start: max(.zero, time - seekTolerance), duration: duration - max(.zero, time - seekTolerance))
        }

        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw NSError(domain: "HomeViewModel", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Unable to attach video output reader."
            ])
        }

        reader.add(output)
        guard reader.startReading() else {
            throw NSError(domain: "HomeViewModel", code: 3, userInfo: [
                NSLocalizedDescriptionKey: reader.error?.localizedDescription ?? "Unable to start reading video frames."
            ])
        }

        assetReader = reader
        trackOutput = output
    }

    private func playLocked() {
        guard isStopped == false else { return }
        guard hasPreparedVideo else {
            startStreaming()
            return
        }

        if reachedEndOfVideo, frameBuffer.isEmpty {
            seekLocked(to: currentTime, autoplay: true)
            return
        }

        setPlaybackState(.playing)
        notifyStatus("Playing at \(currentFPS) FPS.")
        requestDecodeLocked(generation: generation, minimumCount: targetBufferSize)
        startTimerLocked()
    }

    private func pauseLocked() {
        stopTimerLocked()
        setPlaybackState(.paused)
        notifyStatus("Paused at \(formatSeconds(currentTime.seconds)).")
    }

    private func completePlaybackLocked() {
        stopTimerLocked()
        setPlaybackState(.completed)
        notifyStatus("Playback completed. Tap Replay to start again.")
    }

    private func failLocked(_ message: String) {
        stopTimerLocked()
        cancelReaderLocked()
        frameBuffer.removeAll(keepingCapacity: true)
        setPlaybackState(.failed(message))
        notifyStatus(message)
    }

    private func startTimerLocked() {
        stopTimerLocked()

        let interval = max(1.0 / Double(currentFPS), 0.001)
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.renderNextFrameLocked()
        }
        playbackTimer = timer
        timer.resume()
    }

    private func stopTimerLocked() {
        playbackTimer?.setEventHandler {}
        playbackTimer?.cancel()
        playbackTimer = nil
    }

    private func cancelReaderLocked() {
        assetReader?.cancelReading()
        assetReader = nil
        trackOutput = nil
    }

    private func renderNextFrameLocked() {
        if frameBuffer.isEmpty {
            if reachedEndOfVideo {
                completePlaybackLocked()
            } else {
                requestDecodeLocked(generation: generation, minimumCount: targetBufferSize)
                notifyStatus("Buffering...")
            }
            return
        }

        guard case .playing = playbackState else { return }

        let frame = frameBuffer.removeFirst()
        lastRenderedFrame = frame
        currentTime = frame.timestamp
        emitFrame(frame)
        emitTimeline(current: currentTime.seconds, duration: duration.seconds)

        if frameBuffer.count <= refillThreshold {
            requestDecodeLocked(generation: generation, minimumCount: targetBufferSize)
        }

        if frameBuffer.isEmpty, reachedEndOfVideo {
            completePlaybackLocked()
        } else {
            notifyStatus("Playing at \(currentFPS) FPS. Buffer \(frameBuffer.count) frames.")
        }
    }

    private func requestDecodeLocked(generation: Int, minimumCount: Int) {
        guard isDecodeInFlight == false else { return }
        guard reachedEndOfVideo == false else { return }
        guard frameBuffer.count < minimumCount else { return }

        isDecodeInFlight = true

        decodeQueue.async { [weak self] in
            guard let self else { return }
            let result = self.decodeFramesBatch(generation: generation, minimumCount: minimumCount)
            self.stateQueue.async { [weak self] in
                guard let self else { return }
                self.isDecodeInFlight = false
                self.applyDecodedBatch(result, generation: generation)
            }
        }
    }

    private func decodeFramesBatch(generation: Int, minimumCount: Int) -> Result<([HomeVideoFrame], Bool), Error> {
        guard let output = trackOutput, let reader = assetReader else {
            return .success(([], true))
        }

        var decodedFrames: [HomeVideoFrame] = []
        let wantedCount = max(1, minimumCount - frameBuffer.count)

        while decodedFrames.count < wantedCount {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    return .failure(NSError(domain: "HomeViewModel", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: reader.error?.localizedDescription ?? "Video reader failed."
                    ]))
                }

                return .success((decodedFrames, true))
            }

            guard let frame = makeFrame(from: sampleBuffer) else {
                continue
            }

            if frame.timestamp + seekTolerance < playbackStartTime {
                continue
            }

            decodedFrames.append(frame)
        }

        return .success((decodedFrames, false))
    }

    private func applyDecodedBatch(_ result: Result<([HomeVideoFrame], Bool), Error>, generation: Int) {
        guard generation == self.generation else { return }

        switch result {
        case .failure(let error):
            failLocked(error.localizedDescription)
        case .success(let payload):
            let (decodedFrames, didReachEnd) = payload
            if frameBuffer.isEmpty, let firstFrame = decodedFrames.first, lastRenderedFrame == nil {
                lastRenderedFrame = firstFrame
                currentTime = firstFrame.timestamp
                emitFrame(firstFrame)
                emitTimeline(current: currentTime.seconds, duration: duration.seconds)
            }

            frameBuffer.append(contentsOf: decodedFrames)
            reachedEndOfVideo = didReachEnd

            if case .loading = playbackState, frameBuffer.isEmpty == false {
                setPlaybackState(.playing)
                notifyStatus("Playing at \(currentFPS) FPS.")
            } else if case .paused = playbackState, let frame = frameBuffer.first, lastRenderedFrame == nil {
                lastRenderedFrame = frame
                currentTime = frame.timestamp
                emitFrame(frame)
                emitTimeline(current: currentTime.seconds, duration: duration.seconds)
            }
        }
    }

    private func makeFrame(from sampleBuffer: CMSampleBuffer) -> HomeVideoFrame? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: preferredTransform)
        let extent = ciImage.extent.integral
        guard let cgImage = ciContext.createCGImage(ciImage, from: extent) else {
            return nil
        }

        return HomeVideoFrame(
            cgImage: cgImage,
            size: displaySize,
            timestamp: normalizedTime(presentationTime)
        )
    }

    private func normalizedTime(_ time: CMTime) -> CMTime {
        guard time.isNumeric else { return .zero }
        if time < .zero { return .zero }
        if duration.isNumeric, time > duration { return duration }
        return time
    }

    private func displaySize(for track: AVAssetTrack) -> CGSize {
        let transformedSize = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
    }
    private func emitFrame(_ frame: HomeVideoFrame) {
        requestPlateDetectionLocked(for: frame, generation: generation)

        DispatchQueue.main.async { [weak self] in
            self?.onFrameReady?(frame)
        }
    }

    private func requestPlateDetectionLocked(for frame: HomeVideoFrame, generation: Int) {
//        guard isPlateDetectionInFlight == false else { return }
//        if lastPlateDetectionTime.isNumeric, frame.timestamp - lastPlateDetectionTime < plateDetectionInterval {
//            return
//        }
//
//        isPlateDetectionInFlight = true
//        lastPlateDetectionTime = frame.timestamp
//
//        licensePlateDetector.detectLicensePlates(in: frame) { [weak self] result in
//            guard let self else { return }
//            self.stateQueue.async { [weak self] in
//                guard let self else { return }
//                self.isPlateDetectionInFlight = false
//                guard generation == self.generation else { return }
//
//                switch result {
//                case .success(let plates):
//                    self.emitLicensePlates(plates)
//                case .failure(let error):
//                    self.emitLicensePlates([])
//                    self.notifyStatus("License plate detection failed: \(error.localizedDescription)")
//                }
//            }
//        }
    }

    private func emitLicensePlates(_ plates: [LicensePlateInfo]) {
        DispatchQueue.main.async { [weak self] in
            self?.onLicensePlatesDetected?(plates)
        }
    }

    private func emitFPS(_ fps: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.onFPSChanged?(fps)
        }
    }

    private func emitTimeline(current: Double, duration: Double) {
        DispatchQueue.main.async { [weak self] in
            self?.onTimelineChanged?(current, duration)
        }
    }

    private func setPlaybackState(_ state: HomePlaybackState) {
        playbackState = state
        DispatchQueue.main.async { [weak self] in
            self?.onPlaybackStateChanged?(state)
        }
    }

    private func notifyStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(message)
        }
    }

    private func formatSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
