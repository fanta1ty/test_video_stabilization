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
        return view
    }()
    
    private lazy var imageView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFill
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
        
        // Configure media options for low latency
        media.addOption(":network-caching=300")
        media.addOption(":clock-jitter=0")
        media.addOption(":clock-synchro=0")
        
        player.media = media
        
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
            applyRotation()
        }
    }
    
    private func applyRotation() {
        guard let pitch = gyroscopeExtractor.neutralPitch,
              let yaw = gyroscopeExtractor.neutralYaw,
              let roll = gyroscopeExtractor.neutralRoll else { return }
        
        // Apply rotation based on the current gyroscope data
        if let currentRotation = gyroscopeExtractor.currentRotation {
            // Extract the rotation angle from the gyroscope data
            let rotationAngle = extractRotationAngle(from: currentRotation)
            
            // Convert angle to radians
            let radians = rotationAngle * CGFloat.pi / 180
            
            // Calculate the scale factor needed to fill the parent after rotation
            let scale = calculateScaleToFillAfterRotation(angle: radians)
            
            // Apply both rotation and scaling to ensure corners reach parent boundaries
            UIView.animate(withDuration: 0.1) {
                // Combine rotation and scaling transformations
                let rotationTransform = CGAffineTransform(rotationAngle: radians)
                let scaledTransform = rotationTransform.scaledBy(x: scale, y: scale)
                
                self.imageView.transform = scaledTransform
            }
        }
    }
    
    private func extractRotationAngle(from rotationString: String) -> CGFloat {
        // Extract the rotation angle from the rotation string
        // Look for the "Rotation: " part and extract the number
        if let rotationRange = rotationString.range(of: "Rotation: ") {
            let startIndex = rotationRange.upperBound
            
            // Find the degree symbol after the start index
            if let endRange = rotationString.range(of: "°", options: [], range: startIndex..<rotationString.endIndex) {
                // Get the substring between "Rotation: " and "°"
                let valueString = String(rotationString[startIndex..<endRange.lowerBound])
                
                // Convert to Double then CGFloat
                if let doubleValue = Double(valueString) {
                    return CGFloat(doubleValue)
                }
            }
        }
        return 0.0
    }
    
    /// Calculate the scale factor needed to ensure the view fills its parent after rotation
    private func calculateScaleToFillAfterRotation(angle: CGFloat) -> CGFloat {
        // For a rectangular view, we need to calculate how much to scale
        // based on the rotation angle to ensure no empty corners
        
        // A simplified approach that works well:
        // When rotated 45°, the scale needed is about 1.4 (√2)
        // When rotated 0° or 90°, the scale needed is 1.0
        
        // Normalize angle to 0-90° range for calculation
        let normalizedAngle = abs(angle.truncatingRemainder(dividingBy: .pi/2))
        
        // Calculate scale - maximum at 45° (π/4)
        // sin(2*angle) gives us a curve that's 0 at 0° and 90°, and 1 at 45°
        let baseScale = 1.0
        let maxExtraScale = 0.42 // sqrt(2) - 1, rounded up slightly for safety
        
        // Scale factor formula - peaks at 45 degrees
        let extraScale = sin(2 * normalizedAngle) * maxExtraScale
        
        return baseScale + extraScale
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
        // Use the container view as the container for the gyroscope extractor
        gyroscopeExtractor = GyroscopeExtractor(imageView: imageView, containerView: containerView)
        gyroscopeExtractor.contentURL = StreamConfig.gyroscopeURL
        gyroscopeExtractor.rotationUpdateHandler = { [weak self] firstRotation, currentRotation in
            DispatchQueue.main.async {
                self?.updateRotationLabels(firstRotation: firstRotation, currentRotation: currentRotation)
                
                // Apply rotation if enabled
                if self?.rotationSwitch.isOn == true &&
                   self?.gyroscopeExtractor.startAutoRotation == true &&
                   self?.currentStreamMode == .vlcPlayer {
                    self?.applyRotation()
                }
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
            UIView.animate(withDuration: 0.3) {
                self.imageView.transform = .identity
            }
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
            UIView.animate(withDuration: 0.3) {
                self.imageView.transform = .identity
            }
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
        print(currentRotation)
    }
}
