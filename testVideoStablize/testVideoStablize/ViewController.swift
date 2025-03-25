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
    // Container view to handle clipping
    private lazy var containerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .black
        view.clipsToBounds = true
        view.layer.shouldRasterize = true
        view.layer.rasterizationScale = UIScreen.main.scale
        return view
    }()
    
    private lazy var imageView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFill
        view.backgroundColor = .black
        view.clipsToBounds = true
        // Setting layer properties for better rendering performance
        view.layer.drawsAsynchronously = true
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
    
    // Performance optimization properties
    private var lastUIUpdateTime: TimeInterval = 0
    private var uiUpdateInterval: TimeInterval = 0.1 // Only update UI every 100ms
    private var rotationChangeThreshold: CGFloat = 1.0 // Only apply rotation if change > 1 degree
    private var lastRotationAngle: CGFloat = 0
    
    // MARK: - Lifecycle Methods
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        
        // Delay stream setup slightly to improve app launch performance
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.setupStream()
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Set up UI in hierarchy before animations
        self.view.layoutIfNeeded()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Ensure core animation works efficiently
        UIView.setAnimationsEnabled(true)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Disable animations to prevent issues when leaving view
        UIView.setAnimationsEnabled(false)
        cleanupStreams()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        // Final cleanup
        imageView.image = nil
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        cleanupStreams()
    }
    
    // MARK: - UI Setup
    private func setupUI() {
        view.backgroundColor = .white
        
        // Add container view
        view.addSubview(containerView)
        
        // Add imageView to container view
        containerView.addSubview(imageView)
        
        // Add other UI elements
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
            // Container view constraints
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0),
            containerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30),
            containerView.heightAnchor.constraint(equalToConstant: 300),
            
            // Image view constraints - fill container view
            imageView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            imageView.widthAnchor.constraint(equalTo: containerView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: containerView.heightAnchor),
            
            // Rotation label and switch constraints
            rotationLabel.topAnchor.constraint(equalTo: containerView.bottomAnchor, constant: 120),
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
        
        // Set the imageView as the drawable for VLC
        player.drawable = imageView
        
        // Configure media
        let media = VLCMedia(url: StreamConfig.vlcStreamURL)
        
        // Optimized configuration for low latency and better performance
        media.addOption(":network-caching=200")  // Reduced from 300 for lower latency
        media.addOption(":clock-jitter=0")
        media.addOption(":clock-synchro=0")
        media.addOption(":sout-mux-caching=0")
        media.addOption(":file-caching=100")
        media.addOption(":live-caching=100")
        media.addOption(":codec=avcodec") // Force software decoding if hardware causes issues
        media.addOption(":no-video-title-show")
        
        player.media = media
        
        // Optimize player
        // Configure video options directly
        media.addOption(":video-filter=adjust")
        media.addOption(":deinterlace=1")
        media.addOption(":deinterlace-mode=blend")
        
        // Set up VLC notifications
        setupVLCNotifications()
        
        // Start playback
        player.play()
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
        
        // Set up time changed notification to apply rotation
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mediaPlayerTimeChanged),
            name: NSNotification.Name(rawValue: "VLCMediaPlayerTimeChanged"),
            object: player
        )
    }
    
    @objc private func mediaPlayerTimeChanged(_ notification: Notification) {
        // When VLC updates the frame, apply rotation
        if rotationSwitch.isOn && gyroscopeExtractor.startAutoRotation {
            // Use a dispatch queue to avoid blocking the VLC playback thread
            DispatchQueue.main.async {
                self.applyRotation()
            }
        }
    }
    
    private func applyRotation() {
        // Get the rotation angle directly from the gyroscope extractor
        let rotationAngle = gyroscopeExtractor.currentRotationAngle
        
        // Skip if change is too small (performance optimization)
        if abs(rotationAngle - lastRotationAngle) < rotationChangeThreshold {
            return
        }
        
        // Convert angle to radians
        let radians = rotationAngle * CGFloat.pi / 180
        
        // Calculate the scale factor needed to fill the parent after rotation
        let scale = calculateScaleToFillAfterRotation(angle: radians)
        
        // Combine rotation and scaling transformations (without animation for better performance)
        let rotationTransform = CGAffineTransform(rotationAngle: radians)
        let scaledTransform = rotationTransform.scaledBy(x: scale, y: scale)
        
        imageView.transform = scaledTransform
        
        // Store last applied angle
        lastRotationAngle = rotationAngle
    }
    
    // This code is no longer needed since we get the angle directly from GyroscopeExtractor
    
    private func calculateScaleToFillAfterRotation(angle: CGFloat) -> CGFloat {
        // For better performance, use a lookup table approach for common angles
        // with a fast path for the most common cases
        
        // If no rotation, no scaling needed
        if angle == 0 || abs(angle - .pi) < 0.01 || abs(angle + .pi) < 0.01 {
            return 1.0
        }
        
        // For 90-degree rotations (including 270/-90), maintain the aspect ratio without scaling
        if abs(abs(angle) - .pi/2) < 0.01 || abs(abs(angle) - 3 * .pi/2) < 0.01 {
            // Calculate container vs content aspect ratio
            let containerAspect = containerView.bounds.width / containerView.bounds.height
            let contentAspect = imageView.bounds.height / imageView.bounds.width // Swapped because rotated 90°
            
            // Scale to fill the width or height depending on aspect ratios
            return max(1.0, containerAspect / contentAspect)
        }
        
        // Normalize angle to 0-90° range for calculation
        let normalizedAngle = abs(angle.truncatingRemainder(dividingBy: .pi/2))
        
        // Calculate diagonal ratio for proper scaling during rotation
        // When rotating, we need to scale to the diagonal to ensure content fills the view
        // This formula expands the content to fill corners during rotation
        let aspectRatio = containerView.bounds.width / containerView.bounds.height
        let sinValue = sin(normalizedAngle)
        let cosValue = cos(normalizedAngle)
        
        // This formula ensures the content always fills the container during rotation
        let widthScale = abs(cosValue) + abs(sinValue * aspectRatio)
        let heightScale = abs(sinValue) + abs(cosValue / aspectRatio)
        
        // Return the scale that ensures content fills both dimensions
        return max(widthScale, heightScale)
    }
    
    private func setupMJPEGStream() {
        mjpegStreamView = MjpegStabilizeStreaming(imageView: imageView)
        mjpegStreamView?.contentURL = StreamConfig.streamURL
        mjpegStreamView?.rotationUpdateHandler = { [weak self] firstRotation, currentRotation in
            // Use the throttled update method
            self?.updateRotationLabels(firstRotation: firstRotation, currentRotation: currentRotation)
        }
        mjpegStreamView?.play()
    }
    
    private func setupGyroscopeExtractor() {
        // Use the container view as the container for the gyroscope extractor
        gyroscopeExtractor = GyroscopeExtractor(imageView: imageView, containerView: containerView)
        gyroscopeExtractor.contentURL = StreamConfig.gyroscopeURL
        
        // Set up rotation handler with the updated signature including rotationAngle
        gyroscopeExtractor.rotationUpdateHandler = { [weak self] firstRotation, currentRotation, rotationAngle in
            guard let self = self else { return }
            
            // Update labels with the new information
            self.updateRotationLabels(firstRotation: firstRotation, currentRotation: currentRotation)
            
            // Defer rotation application to next run loop for better UI responsiveness
            if self.rotationSwitch.isOn == true &&
               self.gyroscopeExtractor.startAutoRotation == true &&
               self.currentStreamMode == .vlcPlayer {
                DispatchQueue.main.async {
                    self.applyRotation()
                }
            }
        }
        
        // Use lower-level URLSession configuration for better network performance
        let urlSessionConfig = URLSessionConfiguration.default
        urlSessionConfig.timeoutIntervalForRequest = 10  // More aggressive timeout
        urlSessionConfig.httpMaximumConnectionsPerHost = 1  // Limit connections
        urlSessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        urlSessionConfig.networkServiceType = .video  // Prioritize video traffic
        
        // Start the stream
        gyroscopeExtractor.playStream()
        
        // Start gyroscope updates with a slight delay to ensure UI is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.gyroscopeExtractor.startGyroscopeUpdates()
        }
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
        
        // Remove notification observers
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: "VLCMediaPlayerStateChanged"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: "VLCMediaPlayerTimeChanged"), object: nil)
    }
    
    // MARK: - VLC Notifications
    @objc private func mediaPlayerStateChanged(_ notification: Notification) {
        guard let player = notification.object as? VLCMediaPlayer else { return }
        
        switch player.state {
        case .error:
            handleVLCError(nil)
        case .ended:
            attemptStreamReconnection()
        case .playing:
            print("VLC is playing")
        default:
            break
        }
    }
    
    // MARK: - UI Action Handlers
    @objc private func toggleRotation(_ sender: UISwitch) {
        gyroscopeExtractor.enableRotation = sender.isOn
        
        // Reset rotation if disabled
        if !sender.isOn {
            // Apply instantly without animation for better performance
            imageView.transform = .identity
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
        
        // Reset rotation if auto rotation is turned off
        if isActive {
            // Apply instantly without animation for better performance
            imageView.transform = .identity
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
        // Throttle UI updates for better performance
        let currentTime = CACurrentMediaTime()
        if currentTime - lastUIUpdateTime < uiUpdateInterval {
            return // Skip this update if too soon
        }
        
        // Update UI
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Only update if text actually changed
            if self.firstRotationLabel.text != firstRotation {
                self.firstRotationLabel.text = firstRotation
            }
            
            let newText = "Data Received: \(currentRotation ?? "N/A")"
            print(newText)
            if self.rotationValueLabel.text != newText {
                self.rotationValueLabel.text = newText
            }
        }
        
        lastUIUpdateTime = currentTime
    }
}

