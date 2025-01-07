import UIKit
import AVKit
import Vision
import CoreImage

class ViewController: UIViewController {
    private let streamURL = URL(string: "http://192.168.1.50:81/trek_stream")!
//    private let streamURL = URL(string: "http://192.168.50.181:8081/mjpeg")!
    
    // Define two UIImageViews
    var imageView1: UIImageView = .init(frame: .zero)
    var imageView2: UIImageView = .init(frame: .zero)
    var mjpegStreamView2: MjpegStabilizeStreaming!
    var mjpegStreamView1: MjpegStreaming!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        // setupImageView(imageView: imageView1)
        setupImageView(imageView: imageView2)
        
//        let mjpegStreamView1 = MjpegStreaming(imageView: imageView1)
//        mjpegStreamView1.contentURL = streamURL
//        mjpegStreamView1.play()
        
        mjpegStreamView2 = MjpegStabilizeStreaming(imageView: imageView2)
        mjpegStreamView2.contentURL = streamURL
        mjpegStreamView2.play()
        
        let rotationSwitch = UISwitch()
        rotationSwitch.isOn = true
        
        let stabilizationSwitch = UISwitch()
        stabilizationSwitch.isOn = true
        
        let rotationLabel = UILabel()
        let stabilizationLabel = UILabel()
        
        rotationLabel.text = "Rotation"
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
        
        NSLayoutConstraint.activate([
            rotationLabel.topAnchor.constraint(equalTo: imageView2.bottomAnchor, constant: 20),
            rotationLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            rotationSwitch.centerYAnchor.constraint(equalTo: rotationLabel.centerYAnchor),
            rotationSwitch.leadingAnchor.constraint(equalTo: rotationLabel.trailingAnchor, constant: 10),
            
            stabilizationLabel.topAnchor.constraint(equalTo: rotationLabel.bottomAnchor, constant: 20),
            stabilizationLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stabilizationSwitch.centerYAnchor.constraint(equalTo: stabilizationLabel.centerYAnchor),
            stabilizationSwitch.leadingAnchor.constraint(equalTo: stabilizationLabel.trailingAnchor, constant: 10)
        ])
    }
    
    @objc func toggleRotation(_ sender: UISwitch) {
        mjpegStreamView2.enableRotation = sender.isOn
    }
    
    @objc func toggleStabilization(_ sender: UISwitch) {
        mjpegStreamView2.enableStabilization = sender.isOn
    }
    
    // Helper function to set up the image views
    private func setupImageView(imageView: UIImageView) {
        view.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
    }
}
