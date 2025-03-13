import Foundation
import UIKit
import AVKit
import Vision
import CoreImage

class GyroscopeExtractor: NSObject, URLSessionDataDelegate {
    
    // MARK: - Enums
    fileprivate enum Status {
        case stopped
        case loading
        case playing
    }
    
    // MARK: - Properties
    private var receivedData = Data()
    private var status: Status = .stopped
    private var frameBuffer = [UIImage]()
    private var frameSkipCounter = 0

    private let frameBufferLimit = 3
    private let frameSkipRate = 2
    private let semaphore = DispatchSemaphore(value: 1)
    private let processingQueue = DispatchQueue(label: "com.mjpegStabilizeStreaming.frames", qos: .userInitiated)

    private var dataTask: URLSessionDataTask?
    private var session: URLSession!
    
    private var neutralRoll: CGFloat?
    private var neutralPitch: CGFloat?
    private var neutralYaw: CGFloat?
    private var firstRotation: String?
    private var currentRotation: String?
    private var isProcessingFrames = false
    
    private let imageStabilizer = ImageStabilizer()
    
    private var gyroTimer: Timer?
    
    // MARK: - Public Properties
    open var authenticationHandler: ((URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?))?
    open var rotationUpdateHandler: ((_ firstRotation: String?, _ currentRotation: String?) -> Void)?
    open var didStartLoading: (() -> Void)?
    open var didFinishLoading: (() -> Void)?
    open var onError: ((Error?) -> Void)?
    open var contentURL: URL?
    open var imageView: UIImageView
    open var enableRotation: Bool = true
    open var enableStabilization: Bool = false
    open var startAutoRotation: Bool = false
    let containerView: UIView

    // MARK: - Initializer
    public init(imageView: UIImageView, containerView: UIView) {
        self.imageView = imageView
        self.containerView = containerView
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    
    deinit {
        dataTask?.cancel()
    }

    // MARK: - Public Methods
    open func play(url: URL) {
        if status == .playing || status == .loading {
            stop()
        }
        contentURL = url
        playStream()
    }

    @objc func playStream() {
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
        guard let threeDimensionAxes = parse3DAxes(from: data) else { return }
        
        setNeutralValues(
            roll: threeDimensionAxes.roll,
            pitch: threeDimensionAxes.pitch,
            yaw: threeDimensionAxes.yaw
        )
        
        _Concurrency.Task {
            await MainActor.run { [weak self] in
                guard let self else { return }
                // guard let image = self.imageView.image else { return }
                // self.processFrame(image: image, axes: threeDimensionAxes)
                self.applyRotationToImageView(self.imageView, axes: threeDimensionAxes)
            }
        }
        
        
        status = .stopped
    }

    open func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let authHandler = authenticationHandler {
            let (disposition, credential) = authHandler(challenge)
            completionHandler(disposition, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Private Methods
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
                    processFrame(image: image, axes: threeDimensionAxes)
                }
                frameSkipCounter += 1
            }
            currentIndex = threeDimensionAxesEndRg.upperBound
        }
        if currentIndex > 0 {
            receivedData.removeSubrange(0..<currentIndex)
        }
    }

    private func processFrame(image: UIImage, axes: ThreeDimension) {
        processingQueue.async {
            let rotatedImage = self.applyRotation(image: image, axes: axes)

            if self.enableStabilization {
                self.stabilizeFrame(rotatedImage ?? image)
            } else if self.enableRotation {
                DispatchQueue.main.async {
                    self.imageView.image = rotatedImage ?? image
                }
            } else {
                DispatchQueue.main.async {
                    self.imageView.image =  image
                }
            }
        }
    }

    private func stabilizeFrame(_ image: UIImage) {
        semaphore.wait()
        frameBuffer.append(image)

        if frameBuffer.count >= frameBufferLimit {
            guard !isProcessingFrames else { return }
            isProcessingFrames = true

            let stabilizedImages = imageStabilizer.stabilized(withImageList: frameBuffer)
            frameBuffer.removeAll()
            semaphore.signal()

            DispatchQueue.main.async {
                stabilizedImages?.forEach { self.imageView.image = $0 as? UIImage }
            }
            isProcessingFrames = false
        } else {
            semaphore.signal()
        }
    }

    private func parse3DAxes(from jsonData: Data) -> ThreeDimension? {
        guard let jsonString = String(data: jsonData, encoding: .utf8),
              let data = jsonString.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = jsonObject as? [String: Double],
              let roll = dict["r"],
              let pitch = dict["p"],
              let yaw = dict["y"] else { return nil }
        return ThreeDimension(pitch: CGFloat(pitch), roll: CGFloat(roll), yaw: CGFloat(yaw))
    }

    private func setNeutralValues(roll: CGFloat, pitch: CGFloat, yaw: CGFloat) {
        guard startAutoRotation, neutralRoll == nil, neutralPitch == nil, neutralYaw == nil else { return }
        neutralRoll = roll
        neutralPitch = pitch
        neutralYaw = yaw
        // firstRotation = "\n- Roll: \(roll)°\n- Pitch: \(pitch)°\n- Yaw: \(yaw)°"
    }

    private func applyRotation(image: UIImage, axes: ThreeDimension) -> UIImage? {
        guard neutralPitch != nil, neutralYaw != nil else { return nil }
        let deltaRoll = axes.roll - self.neutralRoll!
        let deltaYaw = axes.yaw - self.neutralYaw!
        let deltaPitch = axes.pitch - self.neutralPitch!
        
        let deltaRollLog = "Delta roll: \(axes.roll) - (\(self.neutralRoll ?? 0)) = \(deltaRoll)°"
        let deltaYawLog = "Delta yaw: \(axes.yaw) - (\(self.neutralYaw ?? 0)) = \(deltaYaw) °"
        let deltaPitchLog = "Delta pitch: \(axes.pitch) - (\(self.neutralPitch ?? 0)) = \(deltaPitch)°"
        let deltaShow = "Rotation: \(deltaPitch)°"
        
        currentRotation = "\n- Roll: \(axes.roll)°\n- Pitch: \(axes.pitch)°\n- Yaw: \(axes.yaw)°\n\n\(deltaShow)"
        rotationUpdateHandler?(firstRotation, currentRotation)
        
        let delta = self.normalizeAngle(deltaPitch)
        let radians = delta * .pi / 180
        
        let originalSize = image.size
        let rotatedSize = CGRect(origin: .zero, size: originalSize)
            .applying(CGAffineTransform(rotationAngle: radians))
            .integral
            .size
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { context in
            let context = context.cgContext
            context.setFillColor(UIColor.clear.cgColor)
            context.fill(CGRect(origin: .zero, size: rotatedSize))
            
            context.translateBy(x: image.size.width / 2, y: image.size.height / 2)
            context.rotate(by: radians)
            
            image.draw(in: CGRect(
                x: -originalSize.width / 2,
                y: -originalSize.height / 2,
                width: originalSize.width,
                height: originalSize.height
            ))
        }
    }

    private func normalizeAngle(_ angle: CGFloat) -> CGFloat {
        switch abs(angle) {
        case 0...10: return 0
        case 90...110: return 90
        default: return angle
        }
    }
    
    func startGyroscopeUpdates() {
        // Create a timer that fetches gyroscope data every 100ms (10 times per second)
        gyroTimer = Timer.scheduledTimer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(playStream),
            userInfo: nil,
            repeats: true
        )
    }
    
    private func stopGyroscopeUpdates() {
        gyroTimer?.invalidate()
        gyroTimer = nil
    }
    
    private func applyRotationToImageView(_ imageView: UIImageView, axes: ThreeDimension) {
        guard neutralPitch != nil, neutralYaw != nil else { return }
        let deltaRoll = axes.roll - self.neutralRoll!
        let deltaYaw = axes.yaw - self.neutralYaw!
        let deltaPitch = axes.pitch - self.neutralPitch!
        
        let deltaRollLog = "Delta roll: \(axes.roll) - (\(self.neutralRoll ?? 0)) = \(deltaRoll)°"
        let deltaYawLog = "Delta yaw: \(axes.yaw) - (\(self.neutralYaw ?? 0)) = \(deltaYaw) °"
        let deltaPitchLog = "Delta pitch: \(axes.pitch) - (\(self.neutralPitch ?? 0)) = \(deltaPitch)°"
        let deltaShow = "Rotation: \(deltaPitch)°"
        
        currentRotation = "\n- Roll: \(axes.roll)°\n- Pitch: \(axes.pitch)°\n- Yaw: \(axes.yaw)°\n\n\(deltaShow)"
        rotationUpdateHandler?(firstRotation, currentRotation)
        
        let delta = self.normalizeAngle(deltaYaw)
        let radians = delta * .pi / 180
        
        // Apply rotation transform to the UIImageView directly
        UIView.animate(withDuration: 0.1) {
            imageView.transform = CGAffineTransform(rotationAngle: radians)
            
            self.adjustImageViewSizeAfterRotation(imageView, in: self.containerView, angle: radians)
        }
    }
    
    func setupAutoStretchingImageView(_ imageView: UIImageView, in containerView: UIView) {
        // Remove any existing constraints
        imageView.translatesAutoresizingMaskIntoConstraints = false
        
        // Add constraints to make the imageView fill the container
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: containerView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        
        // Set content mode to scale to fill
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
    }
    
    func adjustImageViewSizeAfterRotation(_ imageView: UIImageView, in containerView: UIView, angle: CGFloat) {
        // Calculate the bounds of the rotated view to ensure it fills the container
        let containerBounds = containerView.bounds
        
        // If needed, adjust the frame to ensure the rotated image fills the container
        // This is only necessary for more complex cases where the normal constraints don't work
        
        // For more advanced cases, you might need to adjust the content mode dynamically
        if abs(angle).truncatingRemainder(dividingBy: .pi / 2) < 0.1 {
            // Near 90/270 degrees - might need different aspect handling
            imageView.contentMode = .scaleAspectFill
        } else {
            // Other angles
            imageView.contentMode = .scaleAspectFill
        }
    }
}

