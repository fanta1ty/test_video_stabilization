import UIKit
import MobileVLCKit
import Foundation

// Structure to decode gyroscope data
struct GyroscopeData: Decodable {
    let r: Int // roll
    let p: Int // pitch
    let y: Int // yaw
}

class TestViewController: UIViewController {
    
    // VLC media player
    private var mediaPlayer: VLCMediaPlayer!
    
    // Video container view
    private var videoView: UIView!
    
    // Labels to display gyroscope data
    private var rollLabel: UILabel!
    private var pitchLabel: UILabel!
    private var yawLabel: UILabel!
    
    // Default coordinate label
    private var defaultCoordinateLabel: UILabel!
    
    // Rotation toggle button
    private var rotationToggleButton: UIButton!
    
    // Timer for fetching gyroscope data
    private var gyroTimer: Timer?
    
    // Gyroscope data URL
    private let gyroURL = "http://192.168.1.18/gyroscope"
    
    // Flag to track rotation state
    private var isRotationEnabled = false
    
    // Default (origin) coordinate
    private var defaultCoordinate = GyroscopeData(r: 0, p: 0, y: 0)
    
    // Current gyroscope data
    private var currentGyroData: GyroscopeData?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Set white background
        view.backgroundColor = .white
        
        setupUI()
        setupPlayer()
        startGyroscopeUpdates()
    }
    
    private func setupUI() {
        // Create video container view at the top portion of screen
        videoView = UIView()
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)
        
        // Set constraints to place video at top of screen
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.3) // Use 40% of screen height
        ])
        
        // Add a border for better visibility
        videoView.layer.borderWidth = 1.0
        videoView.layer.borderColor = UIColor.lightGray.cgColor
        
        // Setup gyroscope data labels
        setupGyroscopeLabels()
        
        // Add rotation toggle button
        setupRotationToggleButton()
        
        // Add default coordinate label
        setupDefaultCoordinateLabel()
    }
    
    private func setupGyroscopeLabels() {
        // Create labels container view
        let labelsContainer = UIView()
        labelsContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(labelsContainer)
        
        // Position labels container below video view
        NSLayoutConstraint.activate([
            labelsContainer.topAnchor.constraint(equalTo: videoView.bottomAnchor, constant: 20),
            labelsContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            labelsContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            labelsContainer.heightAnchor.constraint(equalToConstant: 150)
        ])
        
        // Create roll label
        rollLabel = createGyroLabel(title: "Roll (X):")
        pitchLabel = createGyroLabel(title: "Pitch (Y):")
        yawLabel = createGyroLabel(title: "Yaw (Z):")
        
        // Add labels to container
        labelsContainer.addSubview(rollLabel)
        labelsContainer.addSubview(pitchLabel)
        labelsContainer.addSubview(yawLabel)
        
        // Position labels vertically
        NSLayoutConstraint.activate([
            rollLabel.topAnchor.constraint(equalTo: labelsContainer.topAnchor),
            rollLabel.leadingAnchor.constraint(equalTo: labelsContainer.leadingAnchor),
            rollLabel.trailingAnchor.constraint(equalTo: labelsContainer.trailingAnchor),
            rollLabel.heightAnchor.constraint(equalToConstant: 30),
            
            pitchLabel.topAnchor.constraint(equalTo: rollLabel.bottomAnchor, constant: 10),
            pitchLabel.leadingAnchor.constraint(equalTo: labelsContainer.leadingAnchor),
            pitchLabel.trailingAnchor.constraint(equalTo: labelsContainer.trailingAnchor),
            pitchLabel.heightAnchor.constraint(equalToConstant: 30),
            
            yawLabel.topAnchor.constraint(equalTo: pitchLabel.bottomAnchor, constant: 10),
            yawLabel.leadingAnchor.constraint(equalTo: labelsContainer.leadingAnchor),
            yawLabel.trailingAnchor.constraint(equalTo: labelsContainer.trailingAnchor),
            yawLabel.heightAnchor.constraint(equalToConstant: 30)
        ])
    }
    
    private func setupRotationToggleButton() {
        rotationToggleButton = UIButton(type: .system)
        rotationToggleButton.translatesAutoresizingMaskIntoConstraints = false
        rotationToggleButton.setTitle("Start Rotation", for: .normal)
        rotationToggleButton.backgroundColor = .systemGreen
        rotationToggleButton.layer.cornerRadius = 10
        rotationToggleButton.addTarget(self, action: #selector(toggleRotation), for: .touchUpInside)
        
        view.addSubview(rotationToggleButton)
        
        NSLayoutConstraint.activate([
            rotationToggleButton.topAnchor.constraint(equalTo: yawLabel.bottomAnchor, constant: 20),
            rotationToggleButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            rotationToggleButton.widthAnchor.constraint(equalToConstant: 150),
            rotationToggleButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    
    private func setupDefaultCoordinateLabel() {
        defaultCoordinateLabel = UILabel()
        defaultCoordinateLabel.translatesAutoresizingMaskIntoConstraints = false
        defaultCoordinateLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        defaultCoordinateLabel.textColor = .darkGray
        defaultCoordinateLabel.textAlignment = .center
        defaultCoordinateLabel.text = "Default Coordinate: (0, 0, 0)"
        
        view.addSubview(defaultCoordinateLabel)
        
        NSLayoutConstraint.activate([
            defaultCoordinateLabel.topAnchor.constraint(equalTo: rotationToggleButton.bottomAnchor, constant: 20),
            defaultCoordinateLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            defaultCoordinateLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            defaultCoordinateLabel.heightAnchor.constraint(equalToConstant: 30)
        ])
    }
    
    @objc private func toggleRotation() {
        if !isRotationEnabled {
            // Start rotation
            isRotationEnabled = true
            rotationToggleButton.setTitle("Stop Rotation", for: .normal)
            rotationToggleButton.backgroundColor = .red
            
            // Save current coordinates as default
            if let currentData = currentGyroData {
                defaultCoordinate = currentData
                updateDefaultCoordinateLabel()
            }
            
        } else {
            // Stop rotation and save current coordinates as default
            isRotationEnabled = false
            rotationToggleButton.setTitle("Start Rotation", for: .normal)
            rotationToggleButton.backgroundColor = .systemGreen
            
            // Save current coordinates as default
            defaultCoordinate = GyroscopeData(r: 0, p: 0, y: 0)
            updateDefaultCoordinateLabel()
            
            // Reset video view to original position
            videoView.transform = CGAffineTransform.identity
        }
    }
    
    private func updateDefaultCoordinateLabel() {
        defaultCoordinateLabel.text = "Default Coordinate: (\(defaultCoordinate.r), \(defaultCoordinate.p), \(defaultCoordinate.y))"
    }
    
    private func createGyroLabel(title: String) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 17, weight: .medium)
        label.text = "\(title) 0°"
        label.textColor = .darkGray
        label.textAlignment = .left
        return label
    }
    
    private func setupPlayer() {
        // Initialize VLC media player
        mediaPlayer = VLCMediaPlayer()
        mediaPlayer.drawable = videoView
        
        // Set streaming URL
        let streamURL = URL(string: "http://192.168.1.18:81/stream")!
        let media = VLCMedia(url: streamURL)
        
        // Configure media options if needed
        media.addOptions([
            "network-caching": "1000", // Buffering value in ms
            "live-caching": "1000"     // Live stream buffering
        ])
        
        // Set the media to the player
        mediaPlayer.media = media
        
        // Start playback
        mediaPlayer.play()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        // Stop playback when view disappears
        mediaPlayer.stop()
        
        // Stop gyroscope updates
        stopGyroscopeUpdates()
    }
    
    // MARK: - Gyroscope Data Handling
    
    private func startGyroscopeUpdates() {
        // Create a timer that fetches gyroscope data every 100ms (10 times per second)
        gyroTimer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(fetchGyroscopeData), userInfo: nil, repeats: true)
    }
    
    private func stopGyroscopeUpdates() {
        gyroTimer?.invalidate()
        gyroTimer = nil
    }
    
    @objc private func fetchGyroscopeData() {
        guard let url = URL(string: gyroURL) else { return }
        
        let task = URLSession.shared.dataTask(with: url) { [weak self] (data, response, error) in
            guard let self = self,
                  let data = data,
                  error == nil else {
                print("Error fetching gyroscope data: \(error?.localizedDescription ?? "Unknown error")")
                return
            }
            
            do {
                let gyroData = try JSONDecoder().decode(GyroscopeData.self, from: data)
                
                // Update UI on main thread
                DispatchQueue.main.async {
                    self.updateVideoViewRotation(with: gyroData)
                }
            } catch {
                print("Error decoding gyroscope data: \(error.localizedDescription)")
            }
        }
        
        task.resume()
    }
    
    private func updateVideoViewRotation(with gyroData: GyroscopeData) {
        // Store current gyro data
        currentGyroData = gyroData
        
        // Check if rotation is enabled
        guard isRotationEnabled else { return }
        
        // For 2D rotation, we'll primarily use the yaw value (rotation around z-axis)
        // We convert the yaw value to radians for the rotation transform
        let rotationAngle = CGFloat(gyroData.y) * .pi / 180.0
        
        // Apply the rotation transform
        UIView.animate(withDuration: 0.1) {
            // Reset any previous transformations
            self.videoView.transform = CGAffineTransform.identity
            
            // Apply new rotation transform
            self.videoView.transform = CGAffineTransform(rotationAngle: rotationAngle)
        }
        
        // Update gyroscope data labels
        updateGyroscopeLabels(with: gyroData)
    }
    
    private func updateGyroscopeLabels(with gyroData: GyroscopeData) {
        rollLabel.text = "Roll (X): \(gyroData.r)°"
        pitchLabel.text = "Pitch (Y): \(gyroData.p)°"
        yawLabel.text = "Yaw (Z): \(gyroData.y)°"
    }
}
