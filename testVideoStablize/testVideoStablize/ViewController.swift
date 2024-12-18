import UIKit
import AVKit
import Vision
import CoreImage

class ViewController: UIViewController {
//    private let streamURL = URL(string: "http://192.168.1.6:81/stream")!
    private let streamURL = URL(string: "http://192.168.50.181:8081/mjpeg")!
    
    // Define two UIImageViews
    var imageView1: UIImageView = .init(frame: .zero)
    var imageView2: UIImageView = .init(frame: .zero)
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .white
        
        // Setup first UIImageView
        setupImageView(imageView: imageView1)
        imageView1.backgroundColor = .lightGray
        
        // Setup second UIImageView
        setupImageView(imageView: imageView2)
        imageView2.backgroundColor = .darkGray
        
        // Layout the image views
        NSLayoutConstraint.activate([
            // First ImageView (top)
            imageView1.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            imageView1.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            imageView1.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            imageView1.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.4),
            
            // Second ImageView (below the first)
            imageView2.topAnchor.constraint(equalTo: imageView1.bottomAnchor, constant: 20),
            imageView2.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            imageView2.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            imageView2.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
        
        // Play the streams
        let mjpegStreamView1 = MjpegStreaming(imageView: imageView1)
        mjpegStreamView1.contentURL = streamURL
        mjpegStreamView1.play()
        
        let mjpegStreamView2 = MjpegStabilizeStreaming(imageView: imageView2)
        mjpegStreamView2.contentURL = streamURL
        mjpegStreamView2.play()
    }
    
    // Helper function to set up the image views
    private func setupImageView(imageView: UIImageView) {
        view.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
    }
}
