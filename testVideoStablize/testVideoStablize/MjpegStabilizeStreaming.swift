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
    var enableStabilization: Bool = true
    private var firstRotation: Int? = nil

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
            // rotation: 0x7B, 0x22 to 0x22, 0x7D
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
            
            guard let rotateStartRg = receivedData
                .range(
                    of: Data([0x7B, 0x22]),
                    in: currentIndex..<receivedData.count
                ) else {
                break
            }
            
            guard let rotateEndRg = receivedData
                .range(
                    of: Data([0x22, 0x7D]),
                    in: rotateStartRg.upperBound..<receivedData.count
                ) else {
                break
            }
            
            let rotateData  = receivedData.subdata(in: rotateStartRg.lowerBound..<rotateEndRg.upperBound)
            
            if let image = UIImage(data: imageData),
               let rotation = parseRotation(from: rotateData) {
                let anchorRotation = firstRotation ?? -97
                let adjustedRotation = (rotation == anchorRotation) ? 0 : (rotation > anchorRotation ? (rotation + anchorRotation) : (rotation + anchorRotation - 360))
                print("[enableRotation]: \(enableRotation)")
                print("[enableStabilization]: \(enableStabilization)")
                
                let finalImage = enableRotation ? rotateImage(image, by: adjustedRotation) : image
                
                processingQueue.async { [weak self] in
                    guard let self else { return }
                    
                    self.semaphore.wait()
                    self.frameBuffer.append(finalImage)
                    
                    if self.frameBuffer.count >= self.frameBufferLimit {
                        guard !self.isProcessingFrames else { return }
                        self.isProcessingFrames = true
                        
                        DispatchQueue.global(qos: .userInitiated).async {
                            let stabilizedImages = self.enableStabilization ? self.imageStabilizer.stabilized(withImageList: self.frameBuffer) : self.frameBuffer
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
            }
            
            currentIndex = (rotateStartRg.lowerBound..<rotateEndRg.upperBound).upperBound
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
    
    private func rotateImage(_ image: UIImage, by degrees: Int) -> UIImage {
        let radians = CGFloat(degrees) * .pi / 180
        let rotatedSize = CGRect(origin: .zero, size: image.size).applying(CGAffineTransform(rotationAngle: radians)).size
        UIGraphicsBeginImageContext(rotatedSize)
        let context = UIGraphicsGetCurrentContext()!
        
        context.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
        context.rotate(by: radians)
        image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))
        
        let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        
        return rotatedImage
    }
}
