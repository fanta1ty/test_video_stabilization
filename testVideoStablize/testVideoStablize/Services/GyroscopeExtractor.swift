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
    
    // MARK: - Calibration Constants
    private struct CalibrationPoint {
        let physicalAngle: CGFloat
        let roll: CGFloat
        let pitch: CGFloat
        let yaw: CGFloat
    }
    
    // Calibration data based on your measurements
    private let calibrationPoints: [CalibrationPoint] = [
        CalibrationPoint(physicalAngle: 0, roll: -136.00, pitch: 18.00, yaw: -130.00),
        CalibrationPoint(physicalAngle: 90, roll: -101.00, pitch: 42.00, yaw: -36.00),
        CalibrationPoint(physicalAngle: 180, roll: -90.00, pitch: 3.00, yaw: -38.00),
        CalibrationPoint(physicalAngle: -90, roll: -96.00, pitch: -35.00, yaw: -30.00),
        CalibrationPoint(physicalAngle: -180, roll: -92.00, pitch: 3.00, yaw: -36.00)
    ]
    
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
    
    // Indicate which sensor value to use for mapping to physical angle
    private var primaryRotationAxis: RotationAxis = .yaw
    
    // MARK: - Enums
    private enum RotationAxis {
        case roll, pitch, yaw
    }
    
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
        
        // Determine the best sensor axis to use for rotation mapping
        determineBestRotationAxis()
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

    private func normalizeAngle(_ angle: CGFloat) -> CGFloat {
        // Normalize angle for smoother rotation
        var normalized = angle.truncatingRemainder(dividingBy: 360)
        if normalized > 180 {
            normalized -= 360
        } else if normalized < -180 {
            normalized += 360
        }
        
        // Apply dead zone for small angles to prevent jitter
        if abs(normalized) < 2.0 {
            return 0
        }
        
        // Snap to cardinal angles if close
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
            timeInterval: 0.6,
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
    
    // MARK: - Rotation Mapping Methods
    
    // Determine which sensor axis (roll, pitch, or yaw) has the most consistent
    // and useful changes for mapping to physical rotation
    private func determineBestRotationAxis() {
        // Calculate the range of values for each axis
        let rollValues = calibrationPoints.map { $0.roll }
        let pitchValues = calibrationPoints.map { $0.pitch }
        let yawValues = calibrationPoints.map { $0.yaw }
        
        let rollRange = rollValues.max()! - rollValues.min()!
        let pitchRange = pitchValues.max()! - pitchValues.min()!
        let yawRange = yawValues.max()! - yawValues.min()!
        
        // Use the axis with the largest range of values
        if yawRange >= rollRange && yawRange >= pitchRange {
            primaryRotationAxis = .yaw
        } else if pitchRange >= rollRange {
            primaryRotationAxis = .pitch
        } else {
            primaryRotationAxis = .roll
        }
    }
    
    // Map sensor readings to physical angles using the calibration points
    func mapSensorToPhysicalAngle(axes: ThreeDimension) -> CGFloat {
        // Get the sensor value for the chosen axis
        let sensorValue: CGFloat
        switch primaryRotationAxis {
        case .roll:
            sensorValue = axes.roll
        case .pitch:
            sensorValue = axes.pitch
        case .yaw:
            sensorValue = axes.yaw
        }
        
        // Find the two calibration points that the sensor value falls between
        var closestLower: CalibrationPoint?
        var closestUpper: CalibrationPoint?
        var closestPoint: CalibrationPoint?
        var closestDistance: CGFloat = .greatestFiniteMagnitude
        
        for point in calibrationPoints {
            let pointValue: CGFloat
            switch primaryRotationAxis {
            case .roll:
                pointValue = point.roll
            case .pitch:
                pointValue = point.pitch
            case .yaw:
                pointValue = point.yaw
            }
            
            let distance = abs(pointValue - sensorValue)
            if distance < closestDistance {
                closestDistance = distance
                closestPoint = point
            }
            
            if pointValue <= sensorValue && (closestLower == nil || pointValue > getAxisValue(closestLower!, axis: primaryRotationAxis)) {
                closestLower = point
            }
            
            if pointValue >= sensorValue && (closestUpper == nil || pointValue < getAxisValue(closestUpper!, axis: primaryRotationAxis)) {
                closestUpper = point
            }
        }
        
        // If we couldn't find appropriate bounds, use the closest point
        if closestLower == nil || closestUpper == nil {
            return closestPoint!.physicalAngle
        }
        
        // Linear interpolation between the two points
        let lowerValue = getAxisValue(closestLower!, axis: primaryRotationAxis)
        let upperValue = getAxisValue(closestUpper!, axis: primaryRotationAxis)
        
        // Avoid division by zero
        if lowerValue == upperValue {
            return closestLower!.physicalAngle
        }
        
        let proportion = (sensorValue - lowerValue) / (upperValue - lowerValue)
        return closestLower!.physicalAngle + proportion * (closestUpper!.physicalAngle - closestLower!.physicalAngle)
    }
    
    // Helper method to get the value for a specific axis from a calibration point
    private func getAxisValue(_ point: CalibrationPoint, axis: RotationAxis) -> CGFloat {
        switch axis {
        case .roll:
            return point.roll
        case .pitch:
            return point.pitch
        case .yaw:
            return point.yaw
        }
    }
    
    // Updated rotation method using the new mapping
    func applyRotationToImageView(_ imageView: UIImageView, axes: ThreeDimension) {
        guard let neutralRoll = self.neutralRoll,
              let neutralPitch = self.neutralPitch,
              let neutralYaw = self.neutralYaw else { return }
        
        // Format rotation data for display
        let formattedRoll = String(format: "%.2f", axes.roll)
        let formattedPitch = String(format: "%.2f", axes.pitch)
        let formattedYaw = String(format: "%.2f", axes.yaw)
        
        // Map current sensor values to physical degrees
        let currentPhysicalAngle = mapSensorToPhysicalAngle(axes: axes)
        
        // Map neutral sensor values to physical degrees
        let neutralThreeDimension = ThreeDimension(pitch: neutralPitch, roll: neutralRoll, yaw: neutralYaw)
        let neutralPhysicalAngle = mapSensorToPhysicalAngle(axes: neutralThreeDimension)
        
        // Calculate the relative rotation
        let rotationAngle = currentPhysicalAngle - neutralPhysicalAngle
        let formattedDelta = String(format: "%.2f", rotationAngle)
        
        // Update rotation information
        currentRotation = "\n- Roll: \(formattedRoll)°\n- Pitch: \(formattedPitch)°\n- Yaw: \(formattedYaw)°\n\nRotation: \(formattedDelta)°"
        rotationUpdateHandler?(firstRotation, currentRotation)
        
        // Apply normalized rotation
        let normalizedDelta = normalizeAngle(rotationAngle)
        let radians = normalizedDelta * .pi / 180
        
        // Apply rotation transform to the UIImageView directly
        UIView.animate(withDuration: 0.1) {
            imageView.transform = CGAffineTransform(rotationAngle: radians)
        }
    }
}

