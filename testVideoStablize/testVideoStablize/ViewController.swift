import UIKit
import AVKit
import Vision
import CoreImage
import MobileVLCKit

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
    
    // Container for VLC player
    private lazy var vlcContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .black
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
    private var captureTimer: Timer?
    
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
        
        // Add VLC container and imageView (both will cover the same area)
        view.addSubview(vlcContainerView)
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
            // VLC container constraints
            vlcContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
            vlcContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0),
            vlcContainerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30),
            vlcContainerView.heightAnchor.constraint(equalToConstant: 300),
            
            // ImageView constraints (same position as VLC container)
            imageView.leadingAnchor.constraint(equalTo: vlcContainerView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: vlcContainerView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: vlcContainerView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: vlcContainerView.bottomAnchor),
            
            // Rotation label and switch constraints
            rotationLabel.topAnchor.constraint(equalTo: vlcContainerView.bottomAnchor, constant: 150),
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
            
            // Initially hide the imageView - will be shown when rotation is needed
            imageView.isHidden = true
            vlcContainerView.isHidden = false
        case .mjpeg:
            setupMJPEGStream()
            
            // Hide VLC container when using MJPEG
            vlcContainerView.isHidden = true
            imageView.isHidden = false
        }
    }
    
    private func setupVLCPlayerStream() {
        // Initialize VLC media player
        let player = VLCMediaPlayer()
        self.mediaPlayer = player
        
        // Set the vlcContainerView as the drawable for VLC
        player.drawable = vlcContainerView
        
        // Configure media
        
        let media = VLCMedia(url: StreamConfig.vlcStreamURL)
        
        // Configure media options for low latency
        media.addOption(":network-caching=300")
        media.addOption(":clock-jitter=0")
        media.addOption(":clock-synchro=0")
        
        player.media = media
        
        // Set up VLC notifications
        setupVLCNotifications()
        
        // Start playback
        player.play()
        
        // Set up a timer to periodically capture frames for rotation
        startCaptureTimer()
    }
    
    private func startCaptureTimer() {
        // Cancel any existing timer
        captureTimer?.invalidate()
        
        // Create a timer for frame capture (only runs when rotation is enabled)
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Only capture frames when rotation is enabled and auto rotation is active
            if self.rotationSwitch.isOn &&
               self.gyroscopeExtractor.startAutoRotation &&
               self.imageView.isHidden {
                self.captureVLCFrameAndSwitchToImageView()
            }
        }
    }
    
    private func setupVLCNotifications() {
        guard let player = mediaPlayer else { return }
        
        // Set up state changed notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mediaPlayerStateChanged),
            name: NSNotification.Name(rawValue: "VLCMediaPlayerStateChanged"),
            object: player
        )
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
        
        // Stop capture timer
        captureTimer?.invalidate()
        captureTimer = nil
        
        // Remove notification observers
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: "VLCMediaPlayerStateChanged"), object: nil)
    }
    
    // MARK: - Frame Capture and View Switching
    
    private func captureVLCFrameAndSwitchToImageView() {
        guard let player = mediaPlayer, player.isPlaying else { return }
        
        // Capture the current frame from VLC
        if let capturedImage = captureVLCFrame() {
            // Set the captured image to the imageView
            imageView.image = capturedImage
            
            // Show imageView and hide VLC
            imageView.isHidden = false
            vlcContainerView.isHidden = true
            
            // Update the gyroscope extractor with the new image
            gyroscopeExtractor.streamDidUpdateImage(capturedImage)
        }
    }
    
    private func captureVLCFrame() -> UIImage? {
        // Use a graphics context to capture the VLC container view
        UIGraphicsBeginImageContextWithOptions(vlcContainerView.bounds.size, false, UIScreen.main.scale)
        defer { UIGraphicsEndImageContext() }
        
        if let context = UIGraphicsGetCurrentContext() {
            vlcContainerView.layer.render(in: context)
            return UIGraphicsGetImageFromCurrentImageContext()
        }
        
        return nil
    }
    
    private func switchToVLCView() {
        // Show VLC view and hide imageView
        vlcContainerView.isHidden = false
        imageView.isHidden = true
        
        // Resume VLC playback if it was paused
        if let player = mediaPlayer, !player.isPlaying {
            player.play()
        }
    }
    
    // MARK: - VLC Notifications
    @objc private func mediaPlayerStateChanged(_ notification: Notification) {
        guard let player = notification.object as? VLCMediaPlayer else { return }
        
        switch player.state {
        case .error:
            handleVLCError(nil)
        case .ended:
            attemptStreamReconnection()
        default:
            break
        }
    }
    
    // MARK: - UI Action Handlers
    @objc private func toggleRotation(_ sender: UISwitch) {
        gyroscopeExtractor.enableRotation = sender.isOn
        
        // Toggle between VLC and imageView based on rotation state
        if sender.isOn && gyroscopeExtractor.startAutoRotation {
            // Next timer tick will switch to imageView
        } else {
            // Switch back to VLC view immediately
            switchToVLCView()
        }
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
        
        // If auto rotation was turned off, switch back to VLC
        if isActive {
            switchToVLCView()
        } else {
            // If auto rotation was turned on, wait for the next timer tick
            // to switch to imageView
        }
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
        firstRotationLabel.text = firstRotation
        rotationValueLabel.text = "Data Received: \(currentRotation ?? "N/A")"
    }
}
