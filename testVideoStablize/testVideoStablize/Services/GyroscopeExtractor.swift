import Foundation
import UIKit
import AVKit
import Vision
import CoreImage

class GyroscopeExtractor: NSObject, URLSessionDataDelegate {
    var rotationImageView: UIImageView? {
        didSet {
            // Update rotation handling to use the new view if set
            if let _ = rotationImageView {
                print("Using separate rotation image view")
            }
        }
    }
    
    func applyRotationToImageOverlay(_ axes: ThreeDimension) {
        // Implementation for applying rotation to overlay view
        // This would need to be called from your rotation update logic
        guard let rotationView = rotationImageView,
              let neutralRoll = self.neutralRoll,
              let neutralPitch = self.neutralPitch,
              let neutralYaw = self.neutralYaw else {
            return
        }
        
        // Calculate delta rotations
        let deltaYaw = axes.yaw - neutralYaw
        
        // Apply rotation to the overlay view
        if enableRotation && startAutoRotation {
            // Use deltaYaw for horizontal rotation
            let normalizedDelta = normalizeAngle(deltaYaw)
            
            // Skip rotation if the angle is very small
            if abs(normalizedDelta) < 0.1 {
                return
            }
            
            // Apply rotation to the overlay view
            DispatchQueue.main.async {
                // Apply rotation transformation
                let radians = normalizedDelta * CGFloat.pi / 180.0
                rotationView.transform = CGAffineTransform(rotationAngle: radians)
            }
        }
    }
    
    // Helper method to normalize angle (copied from your existing implementation)
    private func normalizeAngle(_ angle: CGFloat) -> CGFloat {
        // Keep angle in the -180 to 180 range
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
        
        // Optional: Snap to cardinal angles if close
        let snapAngles: [CGFloat] = [0, 90, 180, -90, -180]
        for snapAngle in snapAngles {
            if abs(normalized - snapAngle) < 5.0 {
                return snapAngle
            }
        }
        
        return normalized
    }
    
    // MARK: - Enums
    
    /// Represents the current status of the gyroscope data stream
    private enum Status {
        case stopped
        case loading
        case playing
    }
    
    // MARK: - Private Properties
    
    // Network & Data Properties
    private var receivedData = Data()
    private var status: Status = .stopped
    private var dataTask: URLSessionDataTask?
    private var session: URLSession!
    private let reconnectQueue = DispatchQueue(label: "com.gyroscopeextractor.reconnect")
    private var reconnectAttempts = 0
    private var isReconnecting = false
    
    // Synchronization
    private let syncQueue = DispatchQueue(label: "com.gyroscopeextractor.sync")
    private let processingQueue = DispatchQueue(label: "com.gyroscopeextractor.processing", qos: .userInitiated)
    private let semaphore = DispatchSemaphore(value: 1)
    
    // Frame Processing
    private var frameBuffer = CircularImageBuffer(capacity: 3)
    private var frameSkipCounter = 0
    private let frameSkipRate = 2
    private var isProcessingFrames = false
    
    // Rotation Values
    private var _neutralRoll: CGFloat?
    private var _neutralPitch: CGFloat?
    private var _neutralYaw: CGFloat?
    private var _firstRotation: String?
    private var _currentRotation: String?
    
    // Image Storage
    private var originalImage: UIImage?
    
    // Timer
    private var gyroTimer: Timer?
    
    // Image processing
    private let imageStabilizer = ImageStabilizer()
    
    // MARK: - Public Properties
    
    /// Handler for authentication challenges
    open var authenticationHandler: ((URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?))?
    
    /// Callback for rotation value updates
    open var rotationUpdateHandler: ((_ firstRotation: String?, _ currentRotation: String?) -> Void)?
    
    /// Callback when stream starts loading
    open var didStartLoading: (() -> Void)?
    
    /// Callback when stream finishes loading
    open var didFinishLoading: (() -> Void)?
    
    /// Callback for errors
    open var onError: ((Error?) -> Void)?
    
    /// URL for gyroscope data
    open var contentURL: URL?
    
    /// ImageView that will display the rotated images
    open var imageView: UIImageView
    
    /// Container view that holds the image view
    let containerView: UIView
    
    /// Flag to enable/disable rotation
    open var enableRotation: Bool = true
    
    /// Flag to enable/disable image stabilization
    open var enableStabilization: Bool = false
    
    /// Flag to toggle automatic rotation
    open var startAutoRotation: Bool = false {
        didSet {
            if startAutoRotation && !oldValue {
                // Reset neutral values when auto rotation is turned on
                resetCalibration()
            }
        }
    }
    
    /// First rotation reference value
    open var firstRotation: String? {
        get {
            syncQueue.sync { _firstRotation }
        }
        set {
            syncQueue.sync { _firstRotation = newValue }
        }
    }
    
    /// Current rotation value
    open var currentRotation: String? {
        get {
            syncQueue.sync { _currentRotation }
        }
        set {
            syncQueue.sync { _currentRotation = newValue }
        }
    }
    
    // MARK: - Computed Properties
    
    /// Thread-safe access to neutralRoll
    private var neutralRoll: CGFloat? {
        get {
            syncQueue.sync { _neutralRoll }
        }
        set {
            syncQueue.sync { _neutralRoll = newValue }
        }
    }
    
    /// Thread-safe access to neutralPitch
    private var neutralPitch: CGFloat? {
        get {
            syncQueue.sync { _neutralPitch }
        }
        set {
            syncQueue.sync { _neutralPitch = newValue }
        }
    }
    
    /// Thread-safe access to neutralYaw
    private var neutralYaw: CGFloat? {
        get {
            syncQueue.sync { _neutralYaw }
        }
        set {
            syncQueue.sync { _neutralYaw = newValue }
        }
    }
    
    // MARK: - Initializer
    
    /// Initialize with the image view that will display rotated content and its container
    /// - Parameters:
    ///   - imageView: The UIImageView to display rotated images
    ///   - containerView: The container view that holds the image view
    public init(imageView: UIImageView, containerView: UIView) {
        self.imageView = imageView
        self.containerView = containerView
        super.init()
        setupURLSession()
    }
    
    deinit {
        stop()
        stopGyroscopeUpdates()
        session.invalidateAndCancel()
    }
    
    // MARK: - Public Methods
    
    /// Play stream with a specific URL
    /// - Parameter url: The URL to fetch gyroscope data from
    open func play(url: URL) {
        if status == .playing || status == .loading {
            stop()
        }
        contentURL = url
        playStream()
    }
    
    /// Play stream using the previously set contentURL
    @objc open func playStream() {
        guard let url = contentURL, status == .stopped else { return }
        
        status = .loading
        DispatchQueue.main.async { self.didStartLoading?() }
        
        receivedData = Data()
        let request = URLRequest(url: url, timeoutInterval: 10)
        dataTask = session.dataTask(with: request)
        dataTask?.resume()
    }
    
    /// Stop the gyroscope data stream
    open func stop() {
        status = .stopped
        dataTask?.cancel()
        dataTask = nil
    }
    
    /// Start periodic gyroscope updates
    open func startGyroscopeUpdates() {
        stopGyroscopeUpdates() // Ensure previous timer is invalidated
        
        gyroTimer = Timer.scheduledTimer(
            timeInterval: 0.1,  // 100ms interval for responsive updates
            target: self,
            selector: #selector(playStream),
            userInfo: nil,
            repeats: true
        )
    }
    
    /// Stop gyroscope updates and clean up resources
    open func stopGyroscopeUpdates() {
        gyroTimer?.invalidate()
        gyroTimer = nil
    }
    
    /// Reset calibration values and restore original image
    open func resetCalibration() {
        syncQueue.sync {
            _neutralRoll = nil
            _neutralPitch = nil
            _neutralYaw = nil
            _firstRotation = nil
            
            // Reset by restoring the original image
            if let originalImage = self.originalImage {
                DispatchQueue.main.async { [weak self] in
                    self?.imageView.image = originalImage
                }
            }
        }
    }
    
    // MARK: - URLSessionDataDelegate
    
    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        reconnectAttempts = 0
        isReconnecting = false
        
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
        
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Process the gyroscope data and apply rotation to image
            DispatchQueue.main.async {
                self.applyRotationToImage(self.imageView, axes: threeDimensionAxes)
            }
        }
        
        status = .stopped
    }
    
    open func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            let nsError = error as NSError
            // Don't report cancellation as an error
            if nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled {
                DispatchQueue.main.async { self.onError?(error) }
                handleStreamError(error)
            }
        }
        
        // Reset status if not stopped explicitly
        if status != .stopped {
            status = .stopped
        }
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
    
    /// Set up the URL session with appropriate configuration
    private func setupURLSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true  // Wait for connectivity when offline
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    
    /// Handle stream errors and attempt to reconnect
    private func handleStreamError(_ error: Error) {
        print("Gyroscope stream error: \(error.localizedDescription)")
        
        // Attempt to reconnect if not manually stopped
        if status != .stopped && !isReconnecting {
            isReconnecting = true
            attemptReconnection()
        }
    }
    
    /// Attempt to reconnect to the stream with exponential backoff
    private func attemptReconnection() {
        reconnectQueue.async { [weak self] in
            guard let self = self else { return }
            
            let delay = self.calculateReconnectDelay()
            print("Attempting to reconnect in \(delay) seconds...")
            
            Thread.sleep(forTimeInterval: delay)
            
            DispatchQueue.main.async {
                self.playStream()
            }
        }
    }
    
    /// Calculate delay for reconnection attempt using exponential backoff
    private func calculateReconnectDelay() -> TimeInterval {
        // Exponential backoff with jitter, maximum 30 seconds
        let exponentialDelay = min(pow(1.5, Double(reconnectAttempts)), 15.0)
        let jitter = Double.random(in: 0...1)
        let delay = exponentialDelay + jitter
        
        reconnectAttempts += 1
        return delay
    }
    
    /// Process received data to extract gyroscope information
    private func processReceivedData() {
        var currentIndex = 0
        while currentIndex < receivedData.count {
            guard let dataStartRg = receivedData.range(of: Data([0x7B, 0x22]), in: currentIndex..<receivedData.count),
                  let dataEndRg = receivedData.range(of: Data([0x22, 0x7D]), in: dataStartRg.upperBound..<receivedData.count) else { break }
            
            let gyroscopeData = receivedData.subdata(in: dataStartRg.lowerBound..<dataEndRg.upperBound)
            
            if let threeDimensionAxes = parse3DAxes(from: gyroscopeData) {
                setNeutralValues(
                    roll: threeDimensionAxes.roll,
                    pitch: threeDimensionAxes.pitch,
                    yaw: threeDimensionAxes.yaw
                )
                
                // Apply rotation
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.applyRotationToImage(self.imageView, axes: threeDimensionAxes)
                }
            }
            
            currentIndex = dataEndRg.upperBound
        }
        
        // Clear processed data
        if currentIndex > 0 {
            receivedData.removeSubrange(0..<currentIndex)
        }
    }
    
    /// Parse 3D axes (roll, pitch, yaw) from JSON data
    private func parse3DAxes(from jsonData: Data) -> ThreeDimension? {
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("Error: Could not convert data to string")
            return nil
        }
        
        // Clean up the string (remove any non-JSON characters)
        var cleanedString = jsonString
        if let firstBrace = jsonString.firstIndex(of: "{"),
           let lastBrace = jsonString.lastIndex(of: "}") {
            let range = firstBrace...lastBrace
            cleanedString = String(jsonString[range])
        }
        
        do {
            guard let data = cleanedString.data(using: .utf8) else {
                print("Error: Could not convert cleaned string to data")
                return nil
            }
            
            guard let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                print("Error: Invalid JSON format")
                return nil
            }
            
            guard let roll = jsonObject["r"] as? Double,
                  let pitch = jsonObject["p"] as? Double,
                  let yaw = jsonObject["y"] as? Double else {
                print("Error: Missing required gyroscope values")
                return nil
            }
            
            return ThreeDimension(pitch: CGFloat(pitch), roll: CGFloat(roll), yaw: CGFloat(yaw))
        } catch {
            print("JSON parsing error: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Set neutral values for gyroscope calibration
    private func setNeutralValues(roll: CGFloat, pitch: CGFloat, yaw: CGFloat) {
        guard startAutoRotation else { return }
        
        syncQueue.sync {
            // Only set if they haven't been set yet
            if _neutralRoll == nil && _neutralPitch == nil && _neutralYaw == nil {
                _neutralRoll = roll
                _neutralPitch = pitch
                _neutralYaw = yaw
                
                let formattedRoll = String(format: "%.2f", roll)
                let formattedPitch = String(format: "%.2f", pitch)
                let formattedYaw = String(format: "%.2f", yaw)
                
                _firstRotation = "\n- Roll: \(formattedRoll)°\n- Pitch: \(formattedPitch)°\n- Yaw: \(formattedYaw)°"
            }
        }
    }
    
    /// Apply rotation to the image content rather than the view
    private func applyRotationToImage(_ imageView: UIImageView, axes: ThreeDimension) {
        guard let neutralRoll = self.neutralRoll,
              let neutralPitch = self.neutralPitch,
              let neutralYaw = self.neutralYaw else {
            return
        }
        
        // Get the current image (use original if available)
        guard let sourceImage = originalImage ?? imageView.image else {
            return
        }
        
        // Store original image if not already stored
        if originalImage == nil {
            originalImage = sourceImage
        }
        
        // Calculate delta rotations
        let deltaRoll = axes.roll - neutralRoll
        let deltaYaw = axes.yaw - neutralYaw
        let deltaPitch = axes.pitch - neutralPitch
        
        // Format current rotation data
        let formattedRoll = String(format: "%.2f", axes.roll)
        let formattedPitch = String(format: "%.2f", axes.pitch)
        let formattedYaw = String(format: "%.2f", axes.yaw)
        let formattedDelta = String(format: "%.2f", deltaPitch)
        
        // Update rotation information
        let rotationInfo = "\n- Roll: \(formattedRoll)°\n- Pitch: \(formattedPitch)°\n- Yaw: \(formattedYaw)°\n\nRotation: \(formattedDelta)°"
        currentRotation = rotationInfo
        
        // Notify handler about rotation updates
        rotationUpdateHandler?(firstRotation, currentRotation)
        
        // Apply rotation if enabled
        if enableRotation && startAutoRotation {
            // Use deltaYaw for horizontal rotation (adjust as needed for your application)
            let normalizedDelta = normalizeAngle(deltaYaw)
            
            // Skip rotation if the angle is very small (optimization)
            if abs(normalizedDelta) < 0.1 {
                return
            }
            
            // For better performance, we'll use a cached rotation approach
            let rotatedImage = rotateImageEfficiently(sourceImage, byDegrees: normalizedDelta)
            
            // Update image view with the rotated image
            DispatchQueue.main.async { [weak self] in
                guard self != nil else { return }
                imageView.image = rotatedImage
            }
        }
    }
    
    /// More efficient image rotation using Core Graphics
    private func rotateImageEfficiently(_ image: UIImage, byDegrees degrees: CGFloat) -> UIImage {
        // Convert degrees to radians
        let radians = degrees * .pi / 180.0
        
        // Calculate new size
        let originalSize = image.size
        let rotatedViewBox = CGRect(origin: .zero, size: originalSize)
            .applying(CGAffineTransform(rotationAngle: radians))
        let rotatedSize = rotatedViewBox.size
        
        // Create the bitmap context - optimize for performance
        UIGraphicsBeginImageContextWithOptions(rotatedSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext(),
              let cgImage = image.cgImage else {
            return image
        }
        
        // Move to center and rotate
        context.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
        context.rotate(by: radians)
        
        // Draw the image
        context.scaleBy(x: 1.0, y: -1.0)
        let drawRect = CGRect(
            x: -originalSize.width / 2,
            y: -originalSize.height / 2,
            width: originalSize.width,
            height: originalSize.height
        )
        
        context.draw(cgImage, in: drawRect)
        
        // Get the rotated image
        guard let rotatedImage = UIGraphicsGetImageFromCurrentImageContext() else {
            return image
        }
        
        return rotatedImage
    }
    
    /// Update the original image when stream provides a new frame
    func streamDidUpdateImage(_ newImage: UIImage) {
        // When getting a new frame from the stream, update the original reference
        originalImage = newImage
    }
}

/// A fixed-size circular buffer for storing and managing image frames
private struct CircularImageBuffer {
    private var images: [UIImage]
    private let capacity: Int
    private var currentIndex = 0
    
    init(capacity: Int) {
        self.capacity = capacity
        self.images = []
        self.images.reserveCapacity(capacity)
    }
    
    mutating func add(_ image: UIImage) {
        if images.count < capacity {
            images.append(image)
        } else {
            images[currentIndex] = image
            currentIndex = (currentIndex + 1) % capacity
        }
    }
    
    func getAllImages() -> [UIImage] {
        if images.count < capacity {
            return images
        } else {
            // Return in correct order (oldest first)
            let part1 = images[currentIndex..<capacity]
            let part2 = images[0..<currentIndex]
            return Array(part1) + Array(part2)
        }
    }
    
    mutating func clear() {
        images.removeAll(keepingCapacity: true)
        currentIndex = 0
    }
}

private class ImageStabilizer {
    func stabilized(withImageList images: [UIImage]) -> [Any]? {
        // Implementation for image stabilization
        // This is a placeholder - you would implement your stabilization algorithm here
        return images
    }
}
