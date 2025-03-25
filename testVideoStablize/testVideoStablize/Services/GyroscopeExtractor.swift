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
    
    var neutralRoll: CGFloat?
    var neutralPitch: CGFloat?
    var neutralYaw: CGFloat?
    var firstRotation: String?
    var currentRotation: String?
    private var isProcessingFrames = false
    
    private let imageStabilizer = ImageStabilizer()
    
    private var gyroTimer: Timer?
    
    // Original image reference for rotation
    private var originalImage: UIImage?
    
    // Calibration values
    private var calibrationMap: [(angle: CGFloat, roll: CGFloat, pitch: CGFloat, yaw: CGFloat)] = [
        (angle: 0.0, roll: -145.0, pitch: 15.0, yaw: 169.0),
        (angle: 90.0, roll: -99.0, pitch: 43.0, yaw: -48.0),
        (angle: 180.0, roll: -92.0, pitch: 2.0, yaw: -22.0),
        (angle: -90.0, roll: -102.0, pitch: -37.0, yaw: -17.0),
        (angle: -180.0, roll: -95.0, pitch: 3.0, yaw: -23.0)
    ]
    
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
    open var startAutoRotation: Bool = false {
        didSet {
            // Reset neutral values when auto rotation is toggled
            if startAutoRotation && !oldValue {
                resetCalibration()
            }
        }
    }
    let containerView: UIView

    // MARK: - Initializer
    public init(imageView: UIImageView, containerView: UIView) {
        self.imageView = imageView
        self.containerView = containerView
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        // Load calibration values if previously saved
        if let savedCalibrationData = UserDefaults.standard.data(forKey: "sensor_calibration_map") {
            if let decodedCalibration = try? JSONDecoder().decode([CalibrationPoint].self, from: savedCalibrationData) {
                calibrationMap = decodedCalibration.map { point in
                    return (angle: point.angle, roll: point.roll, pitch: point.pitch, yaw: point.yaw)
                }
            }
        }
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
    
    /// Reset calibration values
    open func resetCalibration() {
        neutralRoll = nil
        neutralPitch = nil
        neutralYaw = nil
        firstRotation = nil
        
        // Reset rotation on the image view
        DispatchQueue.main.async { [weak self] in
            self?.imageView.transform = .identity
        }
    }
    
    /// Update the original image for rotation
    open func streamDidUpdateImage(_ image: UIImage) {
        originalImage = image
        
        // If we have a new image and rotation is active, apply the rotation
        if enableRotation && startAutoRotation,
           let roll = neutralRoll,
           let pitch = neutralPitch,
           let yaw = neutralYaw {
            
            // Create a fake ThreeDimension with the current neutral values
            // This will trigger a refresh of the rotation based on current angles
            let currentAxes = ThreeDimension(
                pitch: pitch,
                roll: roll,
                yaw: yaw
            )
            
            DispatchQueue.main.async { [weak self] in
                self?.applyRotationToImageView(self!.imageView, axes: currentAxes)
            }
        }
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
                // Apply rotation if enabled
                if self.enableRotation && self.startAutoRotation {
                    self.applyRotationToImageView(self.imageView, axes: threeDimensionAxes)
                }
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
            // Store original image for future reference
            self.originalImage = image
            
            if self.enableRotation && self.startAutoRotation {
                // Apply rotation through direct transform
                DispatchQueue.main.async {
                    self.applyRotationToImageView(self.imageView, axes: axes)
                }
            } else if self.enableStabilization {
                self.stabilizeFrame(image)
            } else {
                DispatchQueue.main.async {
                    self.imageView.image = image
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
        
        let formattedRoll = String(format: "%.2f", roll)
        let formattedPitch = String(format: "%.2f", pitch)
        let formattedYaw = String(format: "%.2f", yaw)
        
        firstRotation = "\n- Roll: \(formattedRoll)°\n- Pitch: \(formattedPitch)°\n- Yaw: \(formattedYaw)°"
    }

    private func applyRotation(image: UIImage, axes: ThreeDimension) -> UIImage? {
        guard neutralRoll != nil else { return nil }
        
        let formattedRoll = String(format: "%.2f", axes.roll)
        let formattedPitch = String(format: "%.2f", axes.pitch)
        let formattedYaw = String(format: "%.2f", axes.yaw)
        
        // Get the rotation angle based on both roll and pitch
        let rotationAngle = getRotationAngleFromSensor(roll: axes.roll, pitch: axes.pitch)
        
        let formattedRotation = String(format: "%.2f", rotationAngle)
        
        currentRotation = "\n- Roll: \(formattedRoll)°\n- Pitch: \(formattedPitch)°\n- Yaw: \(formattedYaw)°\n\nRotation: \(formattedRotation)°"
        rotationUpdateHandler?(firstRotation, currentRotation)
        
        let radians = rotationAngle * .pi / 180
        
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
        // Normalize angle to -180 to 180 range
        var normalized = angle.truncatingRemainder(dividingBy: 360)
        if normalized > 180 {
            normalized -= 360
        } else if normalized < -180 {
            normalized += 360
        }
        
        // For angles near 0, 90, 180, -90, or -180 (within 5 degrees), snap to those values
        let snapAngles: [CGFloat] = [0, 90, 180, -90, -180]
        for snapAngle in snapAngles {
            if abs(normalized - snapAngle) < 5.0 {
                return snapAngle
            }
        }
        
        return normalized
    }
    
    func startGyroscopeUpdates() {
        // Create a timer that fetches gyroscope data every 100ms (10 times per second)
        gyroTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(playStream),
            userInfo: nil,
            repeats: true
        )
    }
    
    func stopGyroscopeUpdates() {
        gyroTimer?.invalidate()
        gyroTimer = nil
    }
    
    // Codable struct for saving calibration
    struct CalibrationPoint: Codable {
        let angle: CGFloat
        let roll: CGFloat
        let pitch: CGFloat
        let yaw: CGFloat
    }
    
    // Get rotation angle using both roll and pitch values with tolerance
    func getRotationAngleFromSensor(roll: CGFloat, pitch: CGFloat) -> CGFloat {
        // Define tolerance (10 degrees)
        let rollTolerance: CGFloat = 10.0
        
        // Define calibration points with their sensor values and corresponding rotation angles
        let calibrationPoints: [(roll: CGFloat, pitch: CGFloat, angle: CGFloat)] = [
            (roll: -145.0, pitch: 15.0, angle: 0.0),     // 0 degrees
            (roll: -99.0, pitch: 43.0, angle: 90.0),     // 90 degrees
            (roll: -92.0, pitch: 2.0, angle: 180.0),     // 180 degrees
            (roll: -102.0, pitch: -37.0, angle: -90.0),  // -90 degrees
            (roll: -95.0, pitch: 3.0, angle: -180.0)     // -180 degrees
        ]
        
        // Check if roll is within tolerance of any calibration point
        var matchingPoints: [(roll: CGFloat, pitch: CGFloat, angle: CGFloat, distance: CGFloat)] = []
        
        for point in calibrationPoints {
            if abs(roll - point.roll) <= rollTolerance {
                // Calculate distance to consider both roll and pitch
                let rollDistance = abs(roll - point.roll)
                let pitchDistance = abs(pitch - point.pitch)
                let totalDistance = rollDistance + pitchDistance
                
                matchingPoints.append((roll: point.roll,
                                       pitch: point.pitch,
                                       angle: point.angle,
                                       distance: totalDistance))
            }
        }
        
        // If we have matching points, select the one with the smallest total distance
        if !matchingPoints.isEmpty {
            matchingPoints.sort { $0.distance < $1.distance }
            return matchingPoints[0].angle
        }
        
        // If not within tolerance of any specific point, return 0
        return 0.0
    }
    
    // Updated rotation method using both roll and pitch values
    func applyRotationToImageView(_ imageView: UIImageView, axes: ThreeDimension) {
        // Format rotation data for display
        let formattedRoll = String(format: "%.2f", axes.roll)
        let formattedPitch = String(format: "%.2f", axes.pitch)
        let formattedYaw = String(format: "%.2f", axes.yaw)
        
        // Get the rotation angle based on both roll and pitch
        let rotationAngle = getRotationAngleFromSensor(roll: axes.roll, pitch: axes.pitch)
        
        // Format for display
        let formattedRotation = String(format: "%.2f", rotationAngle)
        
        // Update rotation information
        currentRotation = "\n- Roll: \(formattedRoll)°\n- Pitch: \(formattedPitch)°\n- Yaw: \(formattedYaw)°\n\nRotation: \(formattedRotation)°"
        rotationUpdateHandler?(firstRotation, currentRotation)
        
        // Convert degree to radians for the transform
        let radians = rotationAngle * .pi / 180
        
        // Apply rotation transform
        UIView.animate(withDuration: 0.1) {
            imageView.transform = CGAffineTransform(rotationAngle: radians)
        }
    }
    
    // Calibration method for easy adjustment
    func calibrateWithMeasurement(
        angle: CGFloat,
        roll: CGFloat,
        pitch: CGFloat,
        yaw: CGFloat
    ) {
        // Update or add the calibration point
        if let index = calibrationMap.firstIndex(where: { $0.angle == angle }) {
            calibrationMap[index] = (angle: angle, roll: roll, pitch: pitch, yaw: yaw)
        } else {
            calibrationMap.append((angle: angle, roll: roll, pitch: pitch, yaw: yaw))
        }
        
        // Sort the calibration map by angle for easier reference
        calibrationMap.sort { $0.angle < $1.angle }
        
        // Save to UserDefaults for persistence
        let codablePoints = calibrationMap.map { CalibrationPoint(angle: $0.angle, roll: $0.roll, pitch: $0.pitch, yaw: $0.yaw) }
        if let encodedData = try? JSONEncoder().encode(codablePoints) {
            UserDefaults.standard.set(encodedData, forKey: "sensor_calibration_map")
        }
        
        // Reset neutral values to force recalibration
        resetCalibration()
    }
    
    // Convenience method to set the default calibration values
    func resetCalibrationToDefaults() {
        calibrationMap = [
            (angle: 0.0, roll: -145.0, pitch: 15.0, yaw: 169.0),
            (angle: 90.0, roll: -99.0, pitch: 43.0, yaw: -48.0),
            (angle: 180.0, roll: -92.0, pitch: 2.0, yaw: -22.0),
            (angle: -90.0, roll: -102.0, pitch: -37.0, yaw: -17.0),
            (angle: -180.0, roll: -95.0, pitch: 3.0, yaw: -23.0)
        ]
        
        // Save to UserDefaults
        let codablePoints = calibrationMap.map { CalibrationPoint(angle: $0.angle, roll: $0.roll, pitch: $0.pitch, yaw: $0.yaw) }
        if let encodedData = try? JSONEncoder().encode(codablePoints) {
            UserDefaults.standard.set(encodedData, forKey: "sensor_calibration_map")
        }
        
        resetCalibration()
    }
}
