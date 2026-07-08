import UIKit
import SnapKit

final class FrameRenderView: UIView {
    override class var layerClass: AnyClass {
        CALayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.contentsGravity = .resizeAspect
        layer.isOpaque = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ frame: HomeVideoFrame) {
        layer.contents = frame.cgImage
    }
}

final class LicensePlateOverlayView: UIView {
    private var plates: [LicensePlateInfo] = []
    private var imageSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(plates: [LicensePlateInfo]) {
        self.plates = plates
        setNeedsDisplay()
    }

    func updateImageSize(_ imageSize: CGSize) {
        self.imageSize = imageSize
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard imageSize.width > 0, imageSize.height > 0, let context = UIGraphicsGetCurrentContext() else {
            return
        }

        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let renderedImageSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let renderedImageRect = CGRect(
            x: (bounds.width - renderedImageSize.width) / 2,
            y: (bounds.height - renderedImageSize.height) / 2,
            width: renderedImageSize.width,
            height: renderedImageSize.height
        )

        context.setLineWidth(2)
        context.setStrokeColor(UIColor.systemYellow.cgColor)
        context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.18).cgColor)

        for plate in plates {
            let displayRect = CGRect(
                x: renderedImageRect.minX + plate.rect.minX * scale,
                y: renderedImageRect.minY + plate.rect.minY * scale,
                width: plate.rect.width * scale,
                height: plate.rect.height * scale
            )

            context.fill(displayRect)
            context.stroke(displayRect)
            drawLabel(for: plate, in: displayRect)
        }
    }

    private func drawLabel(for plate: LicensePlateInfo, in rect: CGRect) {
        let labelText = plate.text?.isEmpty == false
            ? plate.text ?? ""
            : String(format: "%.0f%%", plate.confidence * 100)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: UIColor.black
        ]
        let textSize = labelText.size(withAttributes: attributes)
        let labelRect = CGRect(
            x: rect.minX,
            y: max(rect.minY - textSize.height - 6, 0),
            width: textSize.width + 8,
            height: textSize.height + 4
        )

        UIColor.systemYellow.setFill()
        UIBezierPath(roundedRect: labelRect, cornerRadius: 4).fill()
        labelText.draw(
            in: labelRect.insetBy(dx: 4, dy: 2),
            withAttributes: attributes
        )
    }
}

final class HomeViewController: UIViewController {
    private let viewModel: HomeViewModelProtocol
    private let frameContainerView = UIView()
    private let frameRenderView = FrameRenderView()
    private let licensePlateOverlayView = LicensePlateOverlayView()
    private let statusLabel = UILabel()
    private let controlsStackView = UIStackView()
    private let playPauseButton = UIButton(type: .system)
    private let replayButton = UIButton(type: .system)
    private let fpsValueLabel = UILabel()
    private let fpsSlider = UISlider()
    private let timelineSlider = UISlider()
    private let timelineStackView = UIStackView()
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private var isPlaying = false
    private var isScrubbingTimeline = false
    private var currentDuration = 0.0

    init(viewModel: HomeViewModelProtocol) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
        bindViewModel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.startStreaming()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        viewModel.stopStreaming()
    }

    private func setupView() {
        title = viewModel.title
        view.backgroundColor = .systemBackground

        frameContainerView.backgroundColor = .black
        frameContainerView.layer.cornerRadius = 16
        frameContainerView.clipsToBounds = true

        frameRenderView.backgroundColor = .black

        statusLabel.textColor = .secondaryLabel
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        controlsStackView.axis = .horizontal
        controlsStackView.distribution = .fillEqually
        controlsStackView.spacing = 12

        configureButton(playPauseButton, title: "Pause", action: #selector(handlePlayPause))
        configureButton(replayButton, title: "Replay", action: #selector(handleReplay))

        fpsValueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        fpsValueLabel.textColor = .label
        fpsValueLabel.textAlignment = .right
        fpsValueLabel.text = "12 FPS"

        fpsSlider.minimumValue = 1
        fpsSlider.maximumValue = 60
        fpsSlider.value = 12
        fpsSlider.addTarget(self, action: #selector(handleFPSSliderChanged), for: .valueChanged)

        currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        currentTimeLabel.textColor = .secondaryLabel
        currentTimeLabel.text = "00:00"

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        durationLabel.textColor = .secondaryLabel
        durationLabel.textAlignment = .right
        durationLabel.text = "00:00"

        timelineSlider.minimumValue = 0
        timelineSlider.maximumValue = 1
        timelineSlider.value = 0
        timelineSlider.addTarget(self, action: #selector(handleTimelineValueChanged), for: .valueChanged)
        timelineSlider.addTarget(self, action: #selector(handleTimelineTouchUp), for: [.touchUpInside, .touchUpOutside])
        timelineSlider.addTarget(self, action: #selector(handleTimelineTouchDown), for: .touchDown)

        timelineStackView.axis = .horizontal
        timelineStackView.spacing = 12
        timelineStackView.alignment = .center

        controlsStackView.addArrangedSubview(playPauseButton)
        controlsStackView.addArrangedSubview(replayButton)

        timelineStackView.addArrangedSubview(currentTimeLabel)
        timelineStackView.addArrangedSubview(timelineSlider)
        timelineStackView.addArrangedSubview(durationLabel)

        currentTimeLabel.snp.makeConstraints { make in
            make.width.equalTo(44)
        }

        durationLabel.snp.makeConstraints { make in
            make.width.equalTo(44)
        }

        view.addSubview(frameContainerView)
        frameContainerView.addSubview(frameRenderView)
        frameContainerView.addSubview(licensePlateOverlayView)
        view.addSubview(controlsStackView)
        view.addSubview(timelineStackView)
        view.addSubview(fpsValueLabel)
        view.addSubview(fpsSlider)
        view.addSubview(statusLabel)

        frameContainerView.snp.makeConstraints { make in
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(16)
            make.top.equalTo(view.safeAreaLayoutGuide).offset(24)
            make.bottom.lessThanOrEqualTo(controlsStackView.snp.top).offset(-24)
            make.height.greaterThanOrEqualTo(220)
        }

        frameRenderView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        licensePlateOverlayView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        controlsStackView.snp.makeConstraints { make in
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(16)
            make.bottom.equalTo(timelineStackView.snp.top).offset(-16)
            make.height.equalTo(44)
        }

        timelineStackView.snp.makeConstraints { make in
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(16)
            make.bottom.equalTo(fpsSlider.snp.top).offset(-16)
        }

        fpsValueLabel.snp.makeConstraints { make in
            make.trailing.equalTo(view.safeAreaLayoutGuide).inset(16)
            make.bottom.equalTo(statusLabel.snp.top).offset(-16)
            make.width.equalTo(80)
        }

        fpsSlider.snp.makeConstraints { make in
            make.leading.equalTo(view.safeAreaLayoutGuide).inset(16)
            make.trailing.equalTo(fpsValueLabel.snp.leading).offset(-12)
            make.centerY.equalTo(fpsValueLabel)
        }

        statusLabel.snp.makeConstraints { make in
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(24)
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(32)
        }
    }

    private func bindViewModel() {
        viewModel.onFrameReady = { [weak self] frame in
            self?.render(frame: frame)
        }

        viewModel.onLicensePlatesDetected = { [weak self] plates in
            self?.licensePlateOverlayView.update(plates: plates)
        }

        viewModel.onStatusChanged = { [weak self] message in
            self?.statusLabel.text = message
        }

        viewModel.onPlaybackStateChanged = { [weak self] state in
            self?.applyPlaybackState(state)
        }

        viewModel.onFPSChanged = { [weak self] fps in
            self?.fpsSlider.setValue(Float(fps), animated: false)
            self?.fpsValueLabel.text = "\(fps) FPS"
        }

        viewModel.onTimelineChanged = { [weak self] current, duration in
            self?.applyTimeline(current: current, duration: duration)
        }
    }

    private func render(frame: HomeVideoFrame) {
        frameRenderView.render(frame)
        licensePlateOverlayView.updateImageSize(CGSize(width: frame.cgImage.width, height: frame.cgImage.height))
        let aspectText = String(format: "%.0fx%.0f", frame.size.width, frame.size.height)
        navigationItem.prompt = "Aspect \(aspectText)"
    }

    private func applyPlaybackState(_ state: HomePlaybackState) {
        switch state {
        case .idle:
            isPlaying = false
            playPauseButton.setTitle("Play", for: .normal)
            playPauseButton.isEnabled = true
        case .loading:
            isPlaying = false
            playPauseButton.setTitle("Loading...", for: .normal)
            playPauseButton.isEnabled = false
        case .playing:
            isPlaying = true
            playPauseButton.setTitle("Pause", for: .normal)
            playPauseButton.isEnabled = true
        case .paused:
            isPlaying = false
            playPauseButton.setTitle("Play", for: .normal)
            playPauseButton.isEnabled = true
        case .completed:
            isPlaying = false
            playPauseButton.setTitle("Play", for: .normal)
            playPauseButton.isEnabled = true
        case .failed(let message):
            isPlaying = false
            playPauseButton.setTitle("Play", for: .normal)
            playPauseButton.isEnabled = true
            statusLabel.text = message
        }
    }

    private func applyTimeline(current: Double, duration: Double) {
        currentDuration = duration
        durationLabel.text = formatSeconds(duration)

        if isScrubbingTimeline == false {
            currentTimeLabel.text = formatSeconds(current)
            if duration > 0 {
                timelineSlider.setValue(Float(current / duration), animated: false)
            } else {
                timelineSlider.setValue(0, animated: false)
            }
        }
    }

    private func configureButton(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 12
        button.setTitleColor(.label, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    @objc
    private func handlePlayPause() {
        if isPlaying {
            viewModel.pause()
        } else {
            viewModel.play()
        }
    }

    @objc
    private func handleReplay() {
        viewModel.replay()
    }

    @objc
    private func handleFPSSliderChanged() {
        let fps = Int(fpsSlider.value.rounded())
        fpsValueLabel.text = "\(fps) FPS"
        viewModel.updateFPS(fps)
    }

    @objc
    private func handleTimelineTouchDown() {
        isScrubbingTimeline = true
    }

    @objc
    private func handleTimelineValueChanged() {
        let current = Double(timelineSlider.value) * currentDuration
        currentTimeLabel.text = formatSeconds(current)
    }

    @objc
    private func handleTimelineTouchUp() {
        isScrubbingTimeline = false
        viewModel.seek(to: timelineSlider.value)
    }

    private func formatSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
