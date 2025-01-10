import Foundation
import UIKit
import AVKit
import Vision
import CoreImage
import opencv2

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
    open var didStartLoading: (() -> Void)?
    open var didFinishLoading: (() -> Void)?
    open var onError: ((Error?) -> Void)?
    open var contentURL: URL?
    open var imageView: UIImageView

    private let imageStabilizer = ImageStabilizer()
    private var frameBuffer = [UIImage]() // Collect frames here
    private let frameBufferLimit = 3
    private let processingQueue = DispatchQueue(label: "com.mjpegStabilizeStreaming.frames")
    private var isProcessingFrames = false
    private let semaphore = DispatchSemaphore(value: 1)
    
    var enableRotation: Bool = true
    var enableStabilization: Bool = false
    
    var neutralRoll: CGFloat?
    var neutralPitch: CGFloat?
    var neutralYaw: CGFloat?
    var originImage: UIImage?

    var rotationUpdateHandler: ((_ firstRotation: Int?, _ currentRotation: String?) -> Void)?
    private var firstRotation: Int? = nil
    private var currentRotation: String? = ""
    var affineTransform: ((CGAffineTransform) -> Void)?
    
    public init(imageView: UIImageView) {
        self.imageView = imageView
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public convenience init(imageView: UIImageView, contentURL: URL) {
        self.init(imageView: imageView)
        self.contentURL = contentURL
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

    // MARK: - URLSessionDataDelegate

    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        
        if status == .loading {
            status = .playing
            DispatchQueue.main.async { self.didFinishLoading?() }
        }
        
        completionHandler(.allow)
    }

    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // print(data.map { String(format: "%02x", $0) }.joined(separator: " "))
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
        } else if let onAuthentication = authenticationHandler {
            (disposition, credential) = onAuthentication(challenge)
        }

        completionHandler(disposition, credential)
    }

    // MARK: - Error Handling
    private func handleError(_ error: Error?) {
        DispatchQueue.main.async {
            self.onError?(error)
        }
    }
    
    private func processReceivedData() {
        var currentIndex = 0
        
        while currentIndex < receivedData.count {
            // A big data contains image + rotation info begins with 0xFF, 0xD8 and ends with 0x22, 0x7D:
            // image: 0xFF, 0xD8 to 0xFF, 0xD9
            // rotation: 0x7B, 0x22 to 0x22, 0x7D by (replaced - not used)
            // 3d axes: {roll, yaw, pitch}: 0x7B 0x22 to 0x22, 0x7D (with format: {"r":"-64","p":"-26","y":"23"})
            
            guard let imgStartRg = receivedData
                .range(
                    of: Data([0xFF, 0xD8]),
                    in: currentIndex..<receivedData.count
                ) else {
                break
            }
            
            guard let imgEndRg = receivedData
                .range(
                    of: Data([0xFF, 0xD9]),
                    in: imgStartRg.upperBound..<receivedData.count
                ) else {
                break
            }
            
            let imageData  = receivedData.subdata(in: imgStartRg.lowerBound..<imgEndRg.upperBound)
            
            guard let threeDimensionAxesStartRg = receivedData
                .range(
                    of: Data([0x7B, 0x22]),
                    in: currentIndex..<receivedData.count
                ) else {
                break
            }
            
            guard let threeDimensionAxesEndRg = receivedData
                .range(
                    of: Data([0x22, 0x7D]),
                    in: threeDimensionAxesStartRg.upperBound..<receivedData.count
                ) else {
                break
            }
            
            let threeDimensionAxesData  = receivedData.subdata(
                in: threeDimensionAxesStartRg.lowerBound..<threeDimensionAxesEndRg.upperBound
            )
            
            if let image = UIImage(data: imageData),
               let threeDimensionAxes = parse3DAxes(from: threeDimensionAxesData) {

                setNeutralValues(
                    roll: threeDimensionAxes.roll,
                    pitch: threeDimensionAxes.pitch,
                    yaw: threeDimensionAxes.yaw
                )

                let rotateImage = processImageToLandscape(
                    image,
                    roll: threeDimensionAxes.roll,
                    pitch: threeDimensionAxes.pitch,
                    yaw: threeDimensionAxes.yaw
                ) ?? image

                let finalImage = enableRotation ? rotateImage : image

                // neutral position {'r':'-95', 'p':'-48', 'y': '75'}

                if enableStabilization {
                    processingQueue.async { [weak self] in
                        guard let self else { return }

                        self.semaphore.wait()
                        self.frameBuffer.append(finalImage)

                        if self.frameBuffer.count >= self.frameBufferLimit {
                            guard !self.isProcessingFrames else { return }
                            self.isProcessingFrames = true

                            DispatchQueue.global(qos: .userInitiated).async {
                                let stabilizedImages = self.imageStabilizer.stabilized(withImageList: self.frameBuffer)
                                self.frameBuffer.removeAll()

                                DispatchQueue.main.async {
                                    stabilizedImages?.forEach { stabilizedImage in
                                        self.imageView.image = stabilizedImage as? UIImage
                                    }
                                    self.isProcessingFrames = false
                                    self.semaphore.signal()
                                }
                            }
                        } else {
                            self.semaphore.signal()
                        }
                    }
                } else {
                    self.imageView.image = finalImage
                }
            }
            
            currentIndex = (threeDimensionAxesStartRg.lowerBound..<threeDimensionAxesEndRg.upperBound)
                .upperBound
        }
        
        // Clean up processed data
        if currentIndex > 0 {
            receivedData.removeSubrange(0..<currentIndex)
        }
    }
    
    private func parseRotation(from jsonData: Data) -> Int? {
        guard let jsonString = String(data: jsonData, encoding: .utf8),
              let data = jsonString.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let rotationString = (jsonObject as? [String: Any])?["rotate"] as? String,
              let rotation = Int(rotationString) else {
            return nil
        }
        if firstRotation == nil {
            firstRotation = rotation
            print("[First Rotation]: \(String(describing: firstRotation))")
        }
        print("[Rotation]: \(rotationString)")
        
        return rotation
    }
    
    private func parse3DAxes(from jsonData: Data) -> ThreeDimension? {
        guard let jsonString = String(data: jsonData, encoding: .utf8),
              let data = jsonString.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let rotationDict = jsonObject as? [String: Any],
              let r = rotationDict["r"] as? String,
              let p = rotationDict["p"] as? String,
              let y = rotationDict["y"] as? String else {
            return nil
        }
        
        let roll = CGFloat(Double(r) ?? 0)
        let pitch = CGFloat(Double(p) ?? 0)
        let yaw = CGFloat(Double(y) ?? 0)
        
        currentRotation = "[3d]: {'r':'\(r)', 'p':'\(p)', 'y': '\(y)'}"
        rotationUpdateHandler?(firstRotation, currentRotation)

        print("[3d]: {'r':'\(r)', 'p':'\(p)', 'y': '\(y)'}")
        return ThreeDimension(pitch: pitch, roll: roll, yaw: yaw)
    }
    
//    private func rotateImage(_ image: UIImage, by degrees: Int) -> UIImage {
//        let radians = CGFloat(degrees) * .pi / 180
//        let rotatedSize = CGRect(origin: .zero, size: image.size).applying(CGAffineTransform(rotationAngle: radians)).size
//        UIGraphicsBeginImageContext(rotatedSize)
//        let context = UIGraphicsGetCurrentContext()!
//        
//        context.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
//        context.rotate(by: radians)
//        image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))
//        
//        let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()!
//        UIGraphicsEndImageContext()
//        
//        return rotatedImage
//    }

    func rotateImageByPitch(image: UIImage, pitch: CGFloat) -> UIImage? {
        // Convert pitch (in degrees) to radians
        let radians = pitch * .pi / 180
        return rotateImage(image: image, byRadians: radians)
    }

    // Function to rotate an image based on Roll
    func rotateImageByRoll(image: UIImage, roll: CGFloat) -> UIImage? {
        // Convert roll (in degrees) to radians
        let radians = roll * .pi / 180
        return rotateImage(image: image, byRadians: radians)
    }

    // Function to rotate an image based on Yaw
    func rotateImageByYaw(image: UIImage, yaw: CGFloat) -> UIImage? {
        // Convert yaw (in degrees) to radians
        let radians = yaw * .pi / 180
        return rotateImage(image: image, byRadians: radians)
    }

    // General helper function to rotate an image by radians
    func rotateImage(image: UIImage, byRadians radians: CGFloat) -> UIImage? {
        let size = image.size
        let renderer = UIGraphicsImageRenderer(size: size)
        
        let rotatedImage = renderer.image { context in
            let context = context.cgContext
            // Move the origin to the center of the image
            context.translateBy(x: size.width / 2, y: size.height / 2)
            // Rotate the context
            context.rotate(by: radians)
            // Draw the image at the new position
            image.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
        }
        
        return rotatedImage
    }

    func setNeutralValues(roll: Double, pitch: Double, yaw: Double) {
        guard neutralRoll == nil, neutralPitch == nil, neutralYaw == nil else {
            return // Neutral values already set
        }
        
        neutralRoll = roll
        neutralPitch = pitch
        neutralYaw = yaw
        print("Neutral values set - Roll: \(roll), Pitch: \(pitch), Yaw: \(yaw)")
    }

    func processImageToLandscape(_ image: UIImage, roll: CGFloat, pitch: CGFloat, yaw: CGFloat) -> UIImage? {
        guard let neutralRoll = neutralRoll, let neutralPitch = neutralPitch, let neutralYaw = neutralYaw else {
            return nil // Wait until neutral values are set
        }

        // Calculate the delta (difference) between current and neutral orientation
        let deltaRoll = roll - neutralRoll
        let deltaPitch = pitch - neutralPitch
        let deltaYaw = yaw - neutralYaw

        let deltaLog = "1[delta]" + "r: \(deltaRoll) - p: \(deltaPitch) - y: \(deltaYaw)"
        print(deltaLog)


        return applyCounterRotation(to: image, deltaRoll: deltaRoll, deltaYaw: deltaYaw, deltaPitch: deltaPitch)
    }

    func applyCounterRotation(
        to image: UIImage,
        deltaRoll: CGFloat,
        deltaYaw: CGFloat,
        deltaPitch: CGFloat
    ) -> UIImage? {
        let imageWidth = image.size.width
        let imageHeight = image.size.height
        let newSize = CGSize(width: imageWidth, height: imageHeight)

        // Create a graphics context
        UIGraphicsBeginImageContextWithOptions(newSize, false, image.scale)
        guard let context = UIGraphicsGetCurrentContext() else {
            return nil
        }

        // Move the origin to the center (for rotation)
        context.translateBy(x: newSize.width / 2, y: newSize.height / 2)

        // Apply counter rotations (convert degrees to radians)
        let rollRadians = -deltaRoll * .pi / 180
        let yawRadians = -deltaYaw * .pi / 180
        let pitchRadians = -deltaPitch * .pi / 180

        // Combine transformations (3D perspective transformations are limited in CGContext)
        context.rotate(by: rollRadians)

        // For yaw and pitch, we can only approximate with skew transformations in 2D
        let skewTransform = CGAffineTransform(a: 1, b: tan(pitchRadians), c: tan(yawRadians), d: 1, tx: 0, ty: 0)
        context.concatenate(skewTransform)

        // Draw the original image onto the transformed context
        context.translateBy(x: -newSize.width / 2, y: -newSize.height / 2)
        image.draw(in: CGRect(origin: .zero, size: newSize))

        // Extract the transformed image
        let transformedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return transformedImage
    }

}
