import Foundation
import UIKit
import AVKit
import Vision
import CoreImage

class MJPEGFrame {
    var image: UIImage
    var rotation: Int

    init(image: UIImage, rotation: Int) {
        self.image = image
        self.rotation = rotation
    }
}

struct ThreeDimension {
    let pitch: CGFloat
    let roll: CGFloat
    let yaw: CGFloat
}

class MjpegStabilizeStreaming: NSObject, URLSessionDataDelegate {
    
    fileprivate enum Status {
        case stopped
        case loading
        case playing
    }
    
    fileprivate var receivedData = Data()
    private var frames = [MJPEGFrame]()
    
    fileprivate var dataTask: URLSessionDataTask?
    fileprivate var session: URLSession!
    fileprivate var status: Status = .stopped

    open var authenticationHandler: ((URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?))?
    var rotationUpdateHandler: ((_ firstRotation: String?, _ currentRotation: String?) -> Void)?
    open var didStartLoading: (() -> Void)?
    open var didFinishLoading: (() -> Void)?
    open var onError: ((Error?) -> Void)?
    open var contentURL: URL?
    open var imageView: UIImageView

    private var frameBuffer = [UIImage]()
    private let frameBufferLimit = 3
    private let processingQueue = DispatchQueue(label: "com.mjpegStabilizeStreaming.frames", qos: .userInitiated)
    private var isProcessingFrames = false
    private let semaphore = DispatchSemaphore(value: 1)
    
    var enableRotation: Bool = true
    var enableStabilization: Bool = false
    var startAutoRotation: Bool = false
    
    var neutralRoll: CGFloat?
    var neutralPitch: CGFloat?
    var neutralYaw: CGFloat?
    private var firstRotation: String? = ""
    private var currentRotation: String? = ""
    private var frameSkipCounter = 0
    private let frameSkipRate = 2 // Skip every 2nd frame for optimization

    public init(imageView: UIImageView) {
        self.imageView = imageView
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit {
        dataTask?.cancel()
    }

    open func play(url: URL) {
        if status == .playing || status == .loading {
            stop()
        }
        contentURL = url
        play()
    }

    open func play() {
        guard let url = contentURL, status == .stopped else { return }
        status = .loading
        DispatchQueue.main.async { self.didStartLoading?() }
        receivedData = Data()
        let request = URLRequest(url: url)
        dataTask = session.dataTask(with: request)
        dataTask?.resume()
    }

    open func stop() {
        status = .stopped
        dataTask?.cancel()
    }

    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if status == .loading {
            status = .playing
            DispatchQueue.main.async { self.didFinishLoading?() }
        }
        completionHandler(.allow)
    }

    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
        processReceivedData()
    }

    open func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        var credential: URLCredential?
        var disposition: URLSession.AuthChallengeDisposition = .performDefaultHandling
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            credential = URLCredential(trust: trust)
            disposition = .useCredential
        }
        completionHandler(disposition, credential)
    }

    private func processReceivedData() {
        var currentIndex = 0
        while currentIndex < receivedData.count {
            guard let imgStartRg = receivedData.range(of: Data([0xFF, 0xD8]), in: currentIndex..<receivedData.count),
                  let imgEndRg = receivedData.range(of: Data([0xFF, 0xD9]), in: imgStartRg.upperBound..<receivedData.count) else { break }
            
            let imageData = receivedData.subdata(in: imgStartRg.lowerBound..<imgEndRg.upperBound)
            
            guard let threeDimensionAxesStartRg = receivedData.range(of: Data([0x7B, 0x22]), in: currentIndex..<receivedData.count),
                  let threeDimensionAxesEndRg = receivedData.range(of: Data([0x22, 0x7D]), in: threeDimensionAxesStartRg.upperBound..<receivedData.count) else { break }
            
            let threeDimensionAxesData = receivedData.subdata(in: threeDimensionAxesStartRg.lowerBound..<threeDimensionAxesEndRg.upperBound)
            
            if let image = UIImage(data: imageData),
               let threeDimensionAxes = parse3DAxes(from: threeDimensionAxesData) {
                setNeutralValues(roll: threeDimensionAxes.roll, pitch: threeDimensionAxes.pitch, yaw: threeDimensionAxes.yaw)
                
                if frameSkipCounter % frameSkipRate == 0 {
                    processImageToLandscapeAsync(image, roll: threeDimensionAxes.roll, pitch: threeDimensionAxes.pitch, yaw: threeDimensionAxes.yaw) { [weak self] finalImage in
                        guard let self = self else { return }
                        DispatchQueue.main.async {
                            self.imageView.image = finalImage ?? image
                        }
                    }
                }
                frameSkipCounter += 1
            }
            currentIndex = threeDimensionAxesEndRg.upperBound
        }
        if currentIndex > 0 {
            receivedData.removeSubrange(0..<currentIndex)
        }
    }

    private func parse3DAxes(from jsonData: Data) -> ThreeDimension? {
        guard let jsonString = String(data: jsonData, encoding: .utf8),
              let data = jsonString.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = jsonObject as? [String: String] else {
            return nil
        }
        
        // Parse roll, pitch, and yaw safely with optional binding
        guard let rollString = dict["r"], let roll = Double(rollString),
              let pitchString = dict["p"], let pitch = Double(pitchString),
              let yawString = dict["y"], let yaw = Double(yawString) else {
            return nil
        }
        
        return ThreeDimension(pitch: pitch, roll: roll, yaw: yaw)
    }

    private func setNeutralValues(roll: CGFloat, pitch: CGFloat, yaw: CGFloat) {
        guard startAutoRotation == true, neutralRoll == nil, neutralPitch == nil, neutralYaw == nil else { return }
        neutralRoll = roll
        neutralPitch = pitch
        neutralYaw = yaw
        firstRotation = "\n- Roll: \(roll)\n- Pitch: \(pitch)\n- Yaw: \(yaw)"
    }

    private func processImageToLandscapeAsync(_ image: UIImage, roll: CGFloat, pitch: CGFloat, yaw: CGFloat, completion: @escaping (UIImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard self.neutralYaw != nil else { return completion(nil) }
            
            var deltaRoll = pitch - self.neutralPitch!
            
            let deltaRollLog = "Delta roll: \(roll) - (\(self.neutralRoll ?? 0)) = \(self.neutralRoll!)"
            let deltaYawLog = "Delta yaw: \(yaw) - (\(self.neutralYaw ?? 0)) = \(yaw - self.neutralYaw!)"
            let deltaPitchLog = "Delta pitch: \(pitch) - (\(self.neutralPitch ?? 0)) = \(pitch - self.neutralPitch!)"
            
            deltaRoll = normalizeAngle(deltaRoll)
            
            // Update the current and first rotation
            currentRotation = "\n- Roll: \(roll)\n- Pitch: \(pitch)\n- Yaw: \(yaw)\n\n\(deltaRollLog)\n\n\(deltaYawLog)\n\n\(deltaPitchLog)"
            rotationUpdateHandler?(firstRotation, currentRotation)
            
            let processedImage = self.applyRotation(image: image, deltaRoll: deltaRoll)
            completion(processedImage)
        }
    }

    private func applyRotation(image: UIImage, deltaRoll: CGFloat) -> UIImage? {
        let radians = deltaRoll * .pi / 180
        return rotateImage(image: image, byRadians: radians)
    }

    private func rotateImage(image: UIImage, byRadians radians: CGFloat) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { context in
            let context = context.cgContext
            context.translateBy(x: image.size.width / 2, y: image.size.height / 2)
            context.rotate(by: radians)
            image.draw(at: CGPoint(x: -image.size.width / 2, y: -image.size.height / 2))
        }
    }
    
    func normalizeAngle(_ angle: CGFloat) -> CGFloat {
        // Normalize angles for specific cases
        switch abs(angle) {
        case 0...10: return 0

        case 90...110: // Close to 90 degrees
            return 90
            
        default:
            return angle
        }
    }

}
