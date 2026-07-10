import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import QuartzCore

struct HomeVideoFrame {
    /// Raw, unrotated pixel buffer straight from the video output. No
    /// `CGImage` conversion happens for this — the display layer and the
    /// tracking engine both consume the buffer directly.
    let pixelBuffer: CVPixelBuffer
    /// How `pixelBuffer` must be rotated to appear upright.
    let orientation: CGImagePropertyOrientation
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
    var onPlayerChanged: ((AVPlayer?) -> Void)? { get set }
    var onFrameReady: ((HomeVideoFrame) -> Void)? { get set }
    var onVehiclesUpdated: (([VehicleOverlayItem]) -> Void)? { get set }
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

    var onPlayerChanged: ((AVPlayer?) -> Void)?
    var onFrameReady: ((HomeVideoFrame) -> Void)?
    var onVehiclesUpdated: (([VehicleOverlayItem]) -> Void)?
    var onStatusChanged: ((String) -> Void)?
    var onPlaybackStateChanged: ((HomePlaybackState) -> Void)?
    var onFPSChanged: ((Int) -> Void)?
    var onTimelineChanged: ((Double, Double) -> Void)?

    private let stateQueue = DispatchQueue(label: "com.poccv.home.video.state", qos: .userInitiated)
    private let trackingEngine = TrackingEngine()
    private let pixelBufferConverter = PixelBufferConverter()
    private let defaultFPS = 30
    private let minFPS = 1
    private let maxFPS = 60
    private let seekTolerance = CMTime(seconds: 0.05, preferredTimescale: 600)

    private var videoURL: URL?
    private var asset: AVURLAsset?
    private var playerItem: AVPlayerItem?
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var videoTrack: AVAssetTrack?
    private var displaySize = CGSize.zero
    private var preferredTransform = CGAffineTransform.identity
    private var frameOrientation = CGImagePropertyOrientation.up
    private var duration = CMTime.zero

    private var analysisTimer: DispatchSourceTimer?
    private var timelineObserver: Any?
    private var didEndObserver: NSObjectProtocol?
    private var currentFPS = 12
    private var playbackState: HomePlaybackState = .idle
    private var isStopped = false
    private var hasPreparedVideo = false
    private var generation = 0
    private var reachedEndOfVideo = false

    init() {
        currentFPS = defaultFPS
        configureTrackingEngine()
    }

    private func configureTrackingEngine() {
        // Overlay items arrive on the engine's tracking queue; forward to main.
        trackingEngine.onOverlayItems = { [weak self] items in
            self?.emitVehicles(items)
        }
        trackingEngine.onError = { [weak self] error in
            self?.notifyStatus("Detection error: \(error.localizedDescription)")
        }
    }

    deinit {
        removeObserversLocked()
        stopAnalysisTimerLocked()
        player?.pause()
    }

    func setVideoURL(_ url: URL) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.resetPlaybackLocked()
            self.videoURL = url
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
            self.player?.pause()
            self.stopAnalysisTimerLocked()
            self.trackingEngine.reset()
            self.emitVehicles([])
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
                self.startAnalysisTimerLocked()
                self.notifyStatus("Playing. Detecting up to \(clampedFPS) FPS.")
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

        resetPlaybackLocked(keepingURL: true)

        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            failLocked("The provided URL does not contain a video track.")
            return
        }

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        let item = AVPlayerItem(asset: asset)
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause

        self.asset = asset
        self.playerItem = item
        self.player = player
        self.videoOutput = output
        self.videoTrack = videoTrack
        duration = asset.duration
        preferredTransform = videoTrack.preferredTransform
        frameOrientation = VisionGeometry.orientation(fromPreferredTransform: preferredTransform)
        displaySize = displaySize(for: videoTrack)
        hasPreparedVideo = true
        reachedEndOfVideo = false

        addObserversLocked(for: item)
        emitPlayer(player)
        emitTimeline(current: 0, duration: duration.seconds)
        seekLocked(to: .zero, autoplay: true)
    }

    private func playLocked() {
        guard isStopped == false else { return }
        guard hasPreparedVideo else {
            startStreaming()
            return
        }

        if reachedEndOfVideo {
            seekLocked(to: .zero, autoplay: true)
            return
        }

        player?.play()
        setPlaybackState(.playing)
        startAnalysisTimerLocked()
        notifyStatus("Playing. Detecting up to \(currentFPS) FPS.")
    }

    private func pauseLocked() {
        player?.pause()
        stopAnalysisTimerLocked()
        setPlaybackState(.paused)
        notifyStatus("Paused at \(formatSeconds(currentPlaybackTimeLocked().seconds)).")
    }

    private func seekLocked(to time: CMTime, autoplay: Bool) {
        guard hasPreparedVideo, let player else {
            startStreaming()
            return
        }

        generation += 1
        reachedEndOfVideo = false
        trackingEngine.reset()
        emitVehicles([])
        emitTimeline(current: normalizedTime(time).seconds, duration: duration.seconds)

        let targetTime = normalizedTime(time)
        player.seek(to: targetTime, toleranceBefore: seekTolerance, toleranceAfter: seekTolerance) { [weak self] _ in
            guard let self else { return }
            self.stateQueue.async { [weak self] in
                guard let self else { return }
                if autoplay {
                    self.playLocked()
                } else {
                    self.setPlaybackState(.paused)
                    self.notifyStatus("Seeked to \(self.formatSeconds(targetTime.seconds)).")
                }
            }
        }
    }

    private func completePlaybackLocked() {
        stopAnalysisTimerLocked()
        reachedEndOfVideo = true
        setPlaybackState(.completed)
        notifyStatus("Playback completed. Tap Replay to start again.")
    }

    private func failLocked(_ message: String) {
        player?.pause()
        stopAnalysisTimerLocked()
        setPlaybackState(.failed(message))
        notifyStatus(message)
    }

    private func startAnalysisTimerLocked() {
        stopAnalysisTimerLocked()

        let interval = max(1.0 / Double(currentFPS), 0.001)
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.captureFrameForDetectionLocked()
        }
        analysisTimer = timer
        timer.resume()
    }

    private func stopAnalysisTimerLocked() {
        analysisTimer?.setEventHandler {}
        analysisTimer?.cancel()
        analysisTimer = nil
    }

    private func captureFrameForDetectionLocked() {
        guard case .playing = playbackState else { return }
        guard let output = videoOutput else { return }

        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let sourceBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return
        }

        // `copyPixelBuffer` hands back a buffer from the video output's own pool.
        // The tracking engine retains it across several async hops (optical-flow
        // tracking, the throttled CoreML detector, and plate OCR that runs much
        // later), during which the pool can recycle its backing IOSurface — so
        // the models end up reading stale/overwritten pixels and detection fails.
        // Render it into a self-owned BGRA buffer on the GPU (Core Image) first;
        // that copy is decoupled from the AV pool and safe to retain downstream.
        // Both the display layer and the engine consume this converted buffer so
        // the on-screen frame stays exactly the one that was analysed.
        guard let pixelBuffer = pixelBufferConverter.convertToBGRA(sourceBuffer) else {
            return
        }

        let frame = makeFrame(from: pixelBuffer, presentationTime: itemTime)
        emitFrame(frame)

        // Drive the async tracking-by-detection engine at the render cadence.
        // The engine tracks every frame (optical flow) and internally throttles
        // the heavy CoreML detector, so this call never blocks playback.
        trackingEngine.processRenderFrame(pixelBuffer: pixelBuffer, orientation: frameOrientation, timestamp: frame.timestamp)
    }

    private func makeFrame(from pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> HomeVideoFrame {
        HomeVideoFrame(
            pixelBuffer: pixelBuffer,
            orientation: frameOrientation,
            size: displaySize,
            timestamp: normalizedTime(presentationTime)
        )
    }

    private func resetPlaybackLocked(keepingURL: Bool = false) {
        generation += 1
        player?.pause()
        stopAnalysisTimerLocked()
        removeObserversLocked()
        emitPlayer(nil)

        if keepingURL == false {
            videoURL = nil
        }

        asset = nil
        playerItem = nil
        player = nil
        videoOutput = nil
        videoTrack = nil
        duration = .zero
        displaySize = .zero
        preferredTransform = .identity
        frameOrientation = .up
        hasPreparedVideo = false
        isStopped = false
        reachedEndOfVideo = false
        trackingEngine.reset()
        emitVehicles([])
        emitTimeline(current: 0, duration: 0)
        setPlaybackState(.idle)
    }

    private func addObserversLocked(for item: AVPlayerItem) {
        removeObserversLocked()

        timelineObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: stateQueue
        ) { [weak self] time in
            guard let self else { return }
            self.emitTimeline(current: self.normalizedTime(time).seconds, duration: self.duration.seconds)
        }

        didEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: nil
        ) { [weak self] _ in
            self?.stateQueue.async { [weak self] in
                self?.completePlaybackLocked()
            }
        }
    }

    private func removeObserversLocked() {
        if let timelineObserver, let player {
            player.removeTimeObserver(timelineObserver)
        }
        timelineObserver = nil

        if let didEndObserver {
            NotificationCenter.default.removeObserver(didEndObserver)
        }
        didEndObserver = nil
    }

    private func currentPlaybackTimeLocked() -> CMTime {
        normalizedTime(player?.currentTime() ?? .zero)
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

    private func emitPlayer(_ player: AVPlayer?) {
        DispatchQueue.main.async { [weak self] in
            self?.onPlayerChanged?(player)
        }
    }

    private func emitFrame(_ frame: HomeVideoFrame) {
        DispatchQueue.main.async { [weak self] in
            self?.onFrameReady?(frame)
        }
    }

    private func emitVehicles(_ vehicles: [VehicleOverlayItem]) {
        DispatchQueue.main.async { [weak self] in
            self?.onVehiclesUpdated?(vehicles)
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
