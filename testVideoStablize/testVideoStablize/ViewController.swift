import UIKit
import AVKit
import Vision
import CoreImage
import MobileVLCKit

// MARK: - View Controller
class ViewController: UIViewController {
    
    // MARK: - Stream Mode Enum
    private enum StreamMode {
        case vlcPlayer
        case mjpeg
    }
    
    // Current streaming mode
    private let currentStreamMode: StreamMode = .vlcPlayer
    
    // MARK: - UI Components
    private lazy var imageView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFill
        view.backgroundColor = .white
        view.clipsToBounds = true
        return view
    }()
    
    private lazy var rotationSwitch: UISwitch = {
        let toggle = UISwitch()
        toggle.isOn = true
        toggle.addTarget(self, action: #selector(toggleRotation(_:)), for: .valueChanged)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        return toggle
    }()
    
    private lazy var stabilizationSwitch: UISwitch = {
        let toggle = UISwitch()
        toggle.isOn = true
        toggle.addTarget(self, action: #selector(toggleStabilization(_:)), for: .valueChanged)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        return toggle
    }()
    
    private lazy var rotationLabel: UILabel = {
        let label = UILabel()
        label.text = "Auto Rotation & Auto Stabilization"
        label.textColor = .black
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private lazy var stabilizationLabel: UILabel = {
        let label = UILabel()
        label.text = "Stabilization"
        label.textColor = .black
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private lazy var firstRotationLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.textColor = .black
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private lazy var rotationValueLabel: UILabel = {
        let label = UILabel()
        label.text = "Data Received: N/A"
        label.numberOfLines = 0
        label.textColor = .black
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private lazy var startRotateButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Start Auto Rotation & Auto Stabilization", for: .normal)
        button.setTitleColor(.red, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(toggleAutoRotation), for: .touchUpInside)
        return button
    }()
    
    // MARK: - Stream Components
    private var mediaPlayer: VLCMediaPlayer?
    private var gyroscopeExtractor: GyroscopeExtractor!
    private var mjpegStreamView: MjpegStabilizeStreaming?
    
    // VLC delegate handling
    private let vlcEventManager = VLCEventsHandler()
    
    // MARK: - Lifecycle Methods
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupStream()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cleanupStreams()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        cleanupStreams()
    }
    
    // MARK: - UI Setup
    private func setupUI() {
        view.backgroundColor = .white
        
        view.addSubview(imageView)
        view.addSubview(rotationLabel)
        view.addSubview(stabilizationLabel)
        view.addSubview(rotationSwitch)
        view.addSubview(stabilizationSwitch)
        view.addSubview(firstRotationLabel)
        view.addSubview(rotationValueLabel)
        view.addSubview(startRotateButton)
        
        setupConstraints()
    }
    
    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // Image view constraints
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0),
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30),
            imageView.heightAnchor.constraint(equalToConstant: 300),
            
            // Rotation label and switch constraints
            rotationLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 150),
            rotationLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            rotationSwitch.centerYAnchor.constraint(equalTo: rotationLabel.centerYAnchor),
            rotationSwitch.leadingAnchor.constraint(equalTo: rotationLabel.trailingAnchor, constant: 10),
            
            // Stabilization label and switch constraints
            stabilizationLabel.topAnchor.constraint(equalTo: rotationLabel.bottomAnchor, constant: 20),
            stabilizationLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stabilizationSwitch.centerYAnchor.constraint(equalTo: stabilizationLabel.centerYAnchor),
            stabilizationSwitch.leadingAnchor.constraint(equalTo: stabilizationLabel.trailingAnchor, constant: 10),
            
            // Information label constraints
            firstRotationLabel.topAnchor.constraint(equalTo: stabilizationLabel.bottomAnchor, constant: 20),
            firstRotationLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            firstRotationLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 20),
            
            rotationValueLabel.topAnchor.constraint(equalTo: firstRotationLabel.bottomAnchor, constant: 10),
            rotationValueLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            rotationValueLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 20),
            
            // Button constraints
            startRotateButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -15),
            startRotateButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            startRotateButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            startRotateButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }
    
    // MARK: - Stream Setup and Management
    private func setupStream() {
        setupGyroscopeExtractor()
        
        switch currentStreamMode {
        case .vlcPlayer:
            setupVLCPlayerStream()
            // Show stabilization controls
            stabilizationSwitch.isHidden = false
            stabilizationLabel.isHidden = false
        case .mjpeg:
            setupMJPEGStream()
        }
    }
    
    private func setupVLCPlayerStream() {
        // Initialize VLC media player
        let player = VLCMediaPlayer()
        self.mediaPlayer = player
        
        // Set up image container as drawable
        // Note: VLC will render directly to this view
        player.drawable = imageView
        
        // Configure media
        let media = VLCMedia(url: StreamConfig.vlcStreamURL)
        
        // Configure media options for low latency
        media.addOption(":network-caching=300")
        media.addOption(":clock-jitter=0")
        media.addOption(":clock-synchro=0")
        
        player.media = media
        
        // Set up event handling
        setupVLCEvents(for: player)
        
        // Start playback
        player.play()
    }
    
    private func setupVLCEvents(for player: VLCMediaPlayer) {
        // Set up event manager for VLC player
        vlcEventManager.mediaPlayer = player
        
        // Set error handler
        vlcEventManager.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.handleVLCError(error)
            }
        }
        
        // Handle media state changes
        vlcEventManager.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .error:
                    self?.handleVLCError(nil)
                case .ended:
                    self?.attemptStreamReconnection()
                default:
                    break
                }
            }
        }
        
        // Capture frames from VLC for custom processing if needed
        vlcEventManager.onSnapshotTaken = { [weak self] image in
            guard let self = self, let capturedImage = image else { return }
            // Update gyroscope extractor with the new frame
            self.gyroscopeExtractor.streamDidUpdateImage(capturedImage)
        }
    }
    
    private func setupMJPEGStream() {
        mjpegStreamView = MjpegStabilizeStreaming(imageView: imageView)
        mjpegStreamView?.contentURL = StreamConfig.streamURL
        mjpegStreamView?.rotationUpdateHandler = { [weak self] firstRotation, currentRotation in
            DispatchQueue.main.async {
                self?.updateRotationLabels(firstRotation: firstRotation, currentRotation: currentRotation)
            }
        }
        mjpegStreamView?.play()
    }
    
    private func setupGyroscopeExtractor() {
        gyroscopeExtractor = GyroscopeExtractor(imageView: imageView, containerView: view)
        gyroscopeExtractor.contentURL = StreamConfig.gyroscopeURL
        gyroscopeExtractor.rotationUpdateHandler = { [weak self] firstRotation, currentRotation in
            DispatchQueue.main.async {
                self?.updateRotationLabels(firstRotation: firstRotation, currentRotation: currentRotation)
            }
        }
        gyroscopeExtractor.playStream()
        gyroscopeExtractor.startGyroscopeUpdates()
    }
    
    private func cleanupStreams() {
        // Clean up VLC player
        cleanupVLCPlayer()
        
        // Stop MJPEG stream if active
        mjpegStreamView?.stop()
        
        // Stop gyroscope updates
        gyroscopeExtractor.stopGyroscopeUpdates()
    }
    
    private func cleanupVLCPlayer() {
        // Stop VLC playback
        mediaPlayer?.stop()
        mediaPlayer = nil
        
        // Clean up VLC event manager
        vlcEventManager.cleanup()
    }
    
    // MARK: - UI Action Handlers
    @objc private func toggleRotation(_ sender: UISwitch) {
        gyroscopeExtractor.enableRotation = sender.isOn
    }
    
    @objc private func toggleStabilization(_ sender: UISwitch) {
        mjpegStreamView?.enableStabilization = sender.isOn
        
        // If using VLC, apply this to the gyroscope extractor's stabilization flag
        if currentStreamMode == .vlcPlayer {
            gyroscopeExtractor.enableStabilization = sender.isOn
        }
    }
    
    @objc private func toggleAutoRotation() {
        let isActive = gyroscopeExtractor.startAutoRotation
        gyroscopeExtractor.startAutoRotation = !isActive
        
        let buttonTitle = isActive
        ? "Start Auto Rotation & Auto Stabilization"
        : "Stop Auto Rotation & Auto Stabilization"
        startRotateButton.setTitle(buttonTitle, for: .normal)
    }
    
    // MARK: - Error Handling
    private func handleVLCError(_ error: Error?) {
        // Log the error
        if let error = error {
            print("VLC Player error: \(error.localizedDescription)")
        } else {
            print("VLC Player encountered an unknown error")
        }
        
        handleStreamError()
    }
    
    private func handleStreamError() {
        // Show error alert
        let alert = UIAlertController(
            title: "Stream Error",
            message: "There was an error with the video stream. Would you like to try reconnecting?",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reconnect", style: .default) { [weak self] _ in
            self?.attemptStreamReconnection()
        })
        
        present(alert, animated: true)
    }
    
    private func attemptStreamReconnection() {
        // Stop current stream
        cleanupVLCPlayer()
        
        // Try to reconnect after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.setupStream()
        }
    }
    
    // MARK: - UI Updates
    private func updateRotationLabels(firstRotation: String?, currentRotation: String?) {
        rotationValueLabel.text = "Data Received: \(currentRotation ?? "N/A")"
    }
}

// MARK: - VLC Events Handler
class VLCEventsHandler: NSObject {
    
    // Callback closures
    var onStateChange: ((VLCMediaPlayerState) -> Void)?
    var onError: ((Error?) -> Void)?
    var onSnapshotTaken: ((UIImage?) -> Void)?
    
    // Reference to media player
    var mediaPlayer: VLCMediaPlayer? {
        didSet {
            setupEventManager()
        }
    }
    
    private var snapshotTimer: Timer?
    
    // Setup event observer
    private func setupEventManager() {
        guard let player = mediaPlayer else { return }
        
        // Start periodic snapshots for frame capture
        // This allows us to get frames from VLC for rotation
        startSnapshotTimer()
        
        // Listen for state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mediaPlayerStateChanged(_:)),
            name: NSNotification.Name(rawValue: "VLCMediaPlayerStateChanged"),
            object: player
        )
    }
    
    @objc private func mediaPlayerStateChanged(_ notification: Notification) {
        guard let player = notification.object as? VLCMediaPlayer else { return }
        onStateChange?(player.state)
        
        if player.state == .error {
            onError?(nil)
        }
    }
    
    private func startSnapshotTimer() {
        // Take snapshots periodically to update the image for rotation
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.mediaPlayer, player.isPlaying else { return }
            
            // Take snapshot from VLC
            let snapshot = player.lastSnapshot
            self.onSnapshotTaken?(snapshot)
        }
    }
    
    func cleanup() {
        NotificationCenter.default.removeObserver(self)
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        mediaPlayer = nil
    }
    
    deinit {
        cleanup()
    }
}
