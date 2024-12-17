import UIKit
import AVKit
import Vision
import CoreImage

class ViewController: UIViewController {
//    private let streamURL = URL(string: "http://192.168.1.6:81/stream")!
    private let streamURL = URL(string: "http://192.168.50.181:8081/mjpeg")!
    
    var imageView: UIImageView = .init(frame: .zero)
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
                imageView.backgroundColor = .lightGray
        
        // Set constraints for imageView
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),  // 20 points from top
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),             // 20 points from left
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),          // 20 points from right
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor)                          // Square aspect ratio
        ])
        
        let mjpegStreamView = MjpegStreamingController(imageView: imageView)
        mjpegStreamView.contentURL = streamURL
        mjpegStreamView.play()
    }
}

class MjpegStreamingController: NSObject, URLSessionDataDelegate {
    
    fileprivate enum Status {
        case stopped
        case loading
        case playing
    }
    
    fileprivate var receivedData: NSMutableData?
    fileprivate var dataTask: URLSessionDataTask?
    fileprivate var session: Foundation.URLSession!
    fileprivate var status: Status = .stopped
    
    open var authenticationHandler: ((URLAuthenticationChallenge) -> (Foundation.URLSession.AuthChallengeDisposition, URLCredential?))?
    open var didStartLoading: (()->Void)?
    open var didFinishLoading: (()->Void)?
    open var contentURL: URL?
    open var imageView: UIImageView
    
    private var previousObservation: VNDetectedObjectObservation?
    private var previousFrame: CIImage?
    private let context = CIContext(options: [.useSoftwareRenderer: false]) // Hardware-accelerated
    private var imageData = Data()
    
    private var frameCount = 0
    private let frameProcessingInterval = 5  // Process every 5th frame
    
    public init(imageView: UIImageView) {
        self.imageView = imageView
        super.init()
        self.session = Foundation.URLSession(configuration: URLSessionConfiguration.default, delegate: self, delegateQueue: nil)
    }
    
    public convenience init(imageView: UIImageView, contentURL: URL) {
        self.init(imageView: imageView)
        self.contentURL = contentURL
    }
    
    deinit {
        dataTask?.cancel()
    }
    
    open func play(url: URL){
        if status == .playing || status == .loading {
            stop()
        }
        contentURL = url
        play()
    }
    
    open func play() {
        guard let url = contentURL , status == .stopped else {
            return
        }
        
        status = .loading
        DispatchQueue.main.async { self.didStartLoading?() }
        
        receivedData = NSMutableData()
        let request = URLRequest(url: url)
        dataTask = session.dataTask(with: request)
        dataTask?.resume()
    }
    
    open func stop(){
        status = .stopped
        dataTask?.cancel()
    }
    
    // MARK: - NSURLSessionDataDelegate
    
    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let imageData = receivedData , imageData.length > 0 {
            processData(imageData as Data)
            
            if status == .loading {
                status = .playing
                DispatchQueue.main.async { self.didFinishLoading?() }
            }
            
            
        }
        
//        if let imageData = receivedData , imageData.length > 0,
//            let receivedImage = UIImage(data: imageData as Data) {
//            // I'm creating the UIImage before performing didFinishLoading to minimize the interval
//            // between the actions done by didFinishLoading and the appearance of the first image
//            if status == .loading {
//                status = .playing
//                DispatchQueue.main.async { self.didFinishLoading?() }
//            }
            
//            DispatchQueue.main.async { [weak self] in
//                guard let self = self else { return }
//                
//                guard let httpResponse = response as? HTTPURLResponse else {
//                    self.imageView.image = receivedImage
//                    return
//                }
//                
//                let headers = httpResponse.allHeaderFields
//                
//                guard let rotateXString = headers["rotateX"] as? String,
//                      let rotateX = Double(rotateXString) else {
//                    self.imageView.image = receivedImage
//                    return
//                }
//                
//                print("rotateX: \(rotateXString)")
//                // Convert the angle from degrees to radians if needed
//                let radians = CGFloat(rotateX) * .pi / 180
//                
//                // Rotate and scale the image to fit the imageView bounds
//                if let newImage = receivedImage.rotateAndScaleToFit(by: radians, targetSize: self.imageView.bounds.size) {
//                    self.imageView.image = newImage
//                } else {
//                    self.imageView.image = receivedImage // Fallback
//                }
//            }

//        }
        
        receivedData = NSMutableData()
        completionHandler(.allow)
    }
    
    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData?.append(data)
    }
    
    // MARK: - NSURLSessionTaskDelegate
    
    open func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        var credential: URLCredential?
        var disposition: Foundation.URLSession.AuthChallengeDisposition = .performDefaultHandling
        
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let trust = challenge.protectionSpace.serverTrust {
                credential = URLCredential(trust: trust)
                disposition = .useCredential
            }
        } else if let onAuthentication = authenticationHandler {
            (disposition, credential) = onAuthentication(challenge)
        }
        
        completionHandler(disposition, credential)
    }
    
    private func processData(_ data: Data) {
        imageData.append(data)
        
        while let startRange = imageData.range(of: Data([0xFF, 0xD8, 0xFF])) {
            if let endRange = imageData.range(of: Data([0xFF, 0xD9]), in: startRange.lowerBound..<imageData.count) {
                let frameData = self.imageData[startRange.lowerBound..<endRange.upperBound]
                self.imageData.removeSubrange(0..<endRange.upperBound) // Trim used data
                
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.processFrame(data: frameData)
                }
            } else {
                break
            }
        }
    }
    
    private func processFrame(data: Data) {
        guard let uiImage = UIImage(data: data), let ciImage = CIImage(image: uiImage) else { return }
        
        frameCount += 1
        if frameCount % frameProcessingInterval == 0 {
            autoreleasepool {  [weak self] in // Manage memory efficiently
                guard let self else { return }
                let downscaledFrame = ciImage.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
                if let previousFrame = previousFrame {
                    alignAndDisplay(newFrame: downscaledFrame, previousFrame: previousFrame)
                } else {
                    displayFrame(downscaledFrame)
                }
                self.previousFrame = downscaledFrame
            }
        }
    }
    
    private func alignAndDisplay(newFrame: CIImage, previousFrame: CIImage) {
        let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)))
        let handler = VNSequenceRequestHandler()
        
        do {
            try handler.perform([request], on: previousFrame)
            guard let result = request.results?.first as? VNDetectedObjectObservation else {
                displayFrame(newFrame)
                return
            }
            
            let transform = CGAffineTransform(translationX: result.boundingBox.origin.x, y: result.boundingBox.origin.y)
            let stabilizedImage = newFrame.transformed(by: transform)
            displayFrame(stabilizedImage)
        } catch {
            print("Vision request failed: \(error)")
            displayFrame(newFrame)
        }
    }
    
    private func displayFrame(_ frame: CIImage) {
        if let cgImage = context.createCGImage(frame, from: frame.extent) {
            imageView.image = UIImage(cgImage: cgImage)
        }
    }
}

extension UIImage {
    func rotate(by radians: CGFloat) -> UIImage? {
        // Calculate the new size for the rotated image
        let newSize = CGRect(origin: .zero, size: self.size)
            .applying(CGAffineTransform(rotationAngle: radians))
            .integral.size

        // Create a new graphics context with the new size
        UIGraphicsBeginImageContextWithOptions(newSize, false, self.scale)
        guard let context = UIGraphicsGetCurrentContext() else { return nil }

        // Move the origin to the middle of the image to rotate around the center
        context.translateBy(x: newSize.width / 2, y: newSize.height / 2)

        // Apply the rotation
        context.rotate(by: radians)

        // Draw the original image at the rotated position
        self.draw(in: CGRect(x: -self.size.width / 2,
                             y: -self.size.height / 2,
                             width: self.size.width,
                             height: self.size.height))

        // Capture the rotated image
        let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()

        // Clean up the graphics context
        UIGraphicsEndImageContext()

        return rotatedImage
    }
    
    func rotateAndScaleToFit(by radians: CGFloat, targetSize: CGSize) -> UIImage? {
        // Calculate the new bounding box size after rotation
        let rotatedSize = CGRect(origin: .zero, size: self.size)
            .applying(CGAffineTransform(rotationAngle: radians))
            .integral.size
        
        // Calculate the scaling factor to fit the rotated image within the target size
        let scaleX = targetSize.width / rotatedSize.width
        let scaleY = targetSize.height / rotatedSize.height
        let scaleFactor = min(scaleX, scaleY) // Maintain aspect ratio
        
        // Create a new size with the scaling factor
        let scaledSize = CGSize(width: rotatedSize.width * scaleFactor,
                                height: rotatedSize.height * scaleFactor)
        
        // Begin image context with scaled size
        UIGraphicsBeginImageContextWithOptions(targetSize, false, self.scale)
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        // Move context origin to the center to rotate around the image center
        context.translateBy(x: targetSize.width / 2, y: targetSize.height / 2)
        
        // Apply rotation
        context.rotate(by: radians)
        
        // Draw the image at its scaled size
        self.draw(in: CGRect(x: -scaledSize.width / 2,
                             y: -scaledSize.height / 2,
                             width: scaledSize.width,
                             height: scaledSize.height))
        
        // Capture the rotated and scaled image
        let rotatedScaledImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return rotatedScaledImage
    }
}
