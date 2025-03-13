import UIKit
import AVKit
import Vision
import CoreImage
import MobileVLCKit

class ViewController: UIViewController {
    private let streamURL = URL(string: "http://192.168.1.18:81/trek_stream")!
    private let vlcStreamURL = URL(string: "http://192.168.1.18:81/streammm")!
    private let gyroscopeURL = URL(string: "http://192.168.1.18/gyroscope")!
    
    // Define two UIImageViews
    var imageView1: UIImageView = .init(frame: .zero)
    var imageView2: UIImageView = .init(frame: .zero)
    var mjpegStreamView2: MjpegStabilizeStreaming!
    var mjpegStreamView1: MjpegStreaming!
    var gyroscopeExtractor: GyroscopeExtractor!
    
    // Labels to display rotation values
    var firstRotationLabel: UILabel = .init(frame: .zero)
    var rotationValueLabel: UILabel = .init(frame: .zero)
    
    let startRotateButton: UIButton = .init(frame: .zero)
    
    // VLC
    private let mediaPlayer = VLCMediaPlayer()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        // setupImageView(imageView: imageView1)
        setupImageView(imageView: imageView2)
        setupVLCPlayer()
        setupGyroscopeExtractor()
//        setupMjpegStabilizeStreaming()
        
//        let mjpegStreamView1 = MjpegStreaming(imageView: imageView1)
//        mjpegStreamView1.contentURL = streamURL
//        mjpegStreamView1.play()
        
        let rotationSwitch = UISwitch()
        rotationSwitch.isHidden = true
        rotationSwitch.isOn = true
        
        let stabilizationSwitch = UISwitch()
        stabilizationSwitch.isHidden = true
        stabilizationSwitch.isOn = true
        
        let rotationLabel = UILabel()
        rotationLabel.isHidden = true
        rotationLabel.textColor = .black
        
        let stabilizationLabel = UILabel()
        stabilizationLabel.isHidden = true
        stabilizationLabel.textColor = .black
        
        rotationLabel.text = "Auto Rotation & Auto Stabilization"
        stabilizationLabel.text = "Stabilization"
        view.addSubview(rotationLabel)
        view.addSubview(stabilizationLabel)
        
        rotationLabel.translatesAutoresizingMaskIntoConstraints = false
        stabilizationLabel.translatesAutoresizingMaskIntoConstraints = false
        
        rotationSwitch.addTarget(self, action: #selector(toggleRotation(_:)), for: .valueChanged)
        view.addSubview(rotationSwitch)
        
  
        stabilizationSwitch.addTarget(self, action: #selector(toggleStabilization(_:)), for: .valueChanged)
        view.addSubview(stabilizationSwitch)
        
        rotationSwitch.translatesAutoresizingMaskIntoConstraints = false
        stabilizationSwitch.translatesAutoresizingMaskIntoConstraints = false
        
        // Add rotation value labels
        // firstRotationLabel.text = "First: N/A"
        firstRotationLabel.numberOfLines = 0
        firstRotationLabel.textColor = .black
        view.addSubview(firstRotationLabel)
        
        rotationValueLabel.text = "Data Received: N/A"
        rotationValueLabel.numberOfLines = 0
        rotationValueLabel.textColor = .black
        view.addSubview(rotationValueLabel)
        
        firstRotationLabel.translatesAutoresizingMaskIntoConstraints = false
        rotationValueLabel.translatesAutoresizingMaskIntoConstraints = false
        
        startRotateButton.setTitle("Start Auto Rotation & Auto Stabilization", for: .normal)
        startRotateButton.setTitleColor(.red, for: .normal)
        startRotateButton.translatesAutoresizingMaskIntoConstraints = false
        startRotateButton.addTarget(self, action: #selector(onAutoRotation), for: .touchUpInside)
        view.addSubview(startRotateButton)
        
        NSLayoutConstraint.activate([
            imageView2.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
            imageView2.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0),
            imageView2.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30),
            imageView2.heightAnchor.constraint(equalToConstant: 300),
            
            rotationLabel.topAnchor.constraint(equalTo: imageView2.bottomAnchor, constant: 120),
            rotationLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            rotationSwitch.centerYAnchor.constraint(equalTo: rotationLabel.centerYAnchor),
            rotationSwitch.leadingAnchor.constraint(equalTo: rotationLabel.trailingAnchor, constant: 10),
            
            stabilizationLabel.topAnchor.constraint(equalTo: rotationLabel.bottomAnchor, constant: 20),
            stabilizationLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stabilizationSwitch.centerYAnchor.constraint(equalTo: stabilizationLabel.centerYAnchor),
            stabilizationSwitch.leadingAnchor.constraint(equalTo: stabilizationLabel.trailingAnchor, constant: 10),
            
            firstRotationLabel.topAnchor.constraint(equalTo: stabilizationLabel.bottomAnchor, constant: 20),
            firstRotationLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            firstRotationLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 20),
            
            rotationValueLabel.topAnchor.constraint(equalTo: firstRotationLabel.bottomAnchor, constant: 10),
            rotationValueLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            rotationValueLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 20),
            
            startRotateButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -15),
            startRotateButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            startRotateButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            startRotateButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }
    
    private func setupVLCPlayer() {
        validateStreamURL(vlcStreamURL) { [weak self] isValid in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if isValid {
                    self.mediaPlayer.drawable = self.imageView2
                    let media = VLCMedia(url: self.vlcStreamURL)
                    media.addOptions([
                        "network-caching": "1000",
                        "live-caching": "1000"
                    ])
                    self.mediaPlayer.media = media
                    self.mediaPlayer.delegate = self
                    self.mediaPlayer.play()
                } else {
                    self.imageView2.image = UIImage(named: "001_Img")
                }
            }
        }
    }
    
    // check valid or isValid
    private func validateStreamURL(_ url: URL, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                completion(true)
            } else {
                completion(false)
            }
        }
        task.resume()
    }

    
    private func setupMjpegStabilizeStreaming() {
        mjpegStreamView2 = MjpegStabilizeStreaming(imageView: imageView2)
        mjpegStreamView2.contentURL = streamURL
        mjpegStreamView2.rotationUpdateHandler = { [weak self] firstRotation, currentRotation in
            DispatchQueue.main.async {
                self?.updateRotationLabels(firstRotation: firstRotation, currentRotation: currentRotation)
            }
        }
        mjpegStreamView2.play()

    }
    
    private func setupGyroscopeExtractor() {
        gyroscopeExtractor = GyroscopeExtractor(imageView: imageView2, containerView: view)
        gyroscopeExtractor.contentURL = gyroscopeURL
        gyroscopeExtractor.rotationUpdateHandler = { [weak self] firstRotation, currentRotation in
            DispatchQueue.main.async {
                self?.updateRotationLabels(firstRotation: firstRotation, currentRotation: currentRotation)
            }
        }
        gyroscopeExtractor.playStream()
        gyroscopeExtractor.startGyroscopeUpdates()
    }
    
    @objc func toggleRotation(_ sender: UISwitch) {
        // mjpegStreamView2.enableRotation = sender.isOn
        gyroscopeExtractor.enableRotation = sender.isOn
    }
    
    @objc func toggleStabilization(_ sender: UISwitch) {
        mjpegStreamView2.enableStabilization = sender.isOn
    }
    
    @objc func onAutoRotation(_ sender: UIButton) {
//        if mjpegStreamView2.startAutoRotation {
//            startRotateButton.setTitle("Start Auto Rotation & Auto Stabilization", for: .normal)
//            mjpegStreamView2.startAutoRotation = false
//        } else {
//            startRotateButton.setTitle("Stop Auto Rotation & Auto Stabilization", for: .normal)
//            mjpegStreamView2.startAutoRotation = true
//        }
        if gyroscopeExtractor.startAutoRotation {
            startRotateButton.setTitle("Start Auto Rotation & Auto Stabilization", for: .normal)
            gyroscopeExtractor.startAutoRotation = false
        } else {
            startRotateButton.setTitle("Stop Auto Rotation & Auto Stabilization", for: .normal)
            gyroscopeExtractor.startAutoRotation = true
        }
    }
    
    // Helper function to set up the image views
    private func setupImageView(imageView: UIImageView) {
        view.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = .white
        imageView.clipsToBounds = true
    }
    private func updateRotationLabels(firstRotation: String?, currentRotation: String?) {
        // firstRotationLabel.text = "First: \(firstRotation ?? "")"
        rotationValueLabel.text = "Data Received: \(currentRotation ?? "")"
    }
}

extension ViewController: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        if mediaPlayer.state == .error {
            DispatchQueue.main.async {
                self.imageView2.image = UIImage(named: "001_Img")
            }
        }
    }
}
