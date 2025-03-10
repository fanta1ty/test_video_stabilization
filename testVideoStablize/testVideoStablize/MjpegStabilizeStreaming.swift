import Foundation
import UIKit
import AVKit
import Vision
import CoreImage

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
    
    private var receivedData = Data()
    private var status: Status = .stopped
    private var dataTask: URLSessionDataTask?
    private var session: URLSession!
    
    private var neutralRoll: CGFloat?
    private var neutralPitch: CGFloat?
    private var neutralYaw: CGFloat?
    private var currentRotation: String?
    
    open var rotationUpdateHandler: ((_ firstRotation: String?, _ currentRotation: String?) -> Void)?
    open var contentURL: URL?
    open var imageView: UIImageView
    
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
    
    open func play() {
        guard let url = contentURL, status == .stopped else { return }
        status = .loading
        receivedData = Data()
        let request = URLRequest(url: url)
        dataTask = session.dataTask(with: request)
        dataTask?.resume()
    }
    
    open func stop() {
        status = .stopped
        dataTask?.cancel()
    }
    
    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
        processReceivedData()
    }
    
    private func processReceivedData() {
        var currentIndex = 0
        while currentIndex < receivedData.count {
            guard let threeDimensionAxesStartRg = receivedData.range(of: Data([0x7B, 0x22]), in: currentIndex..<receivedData.count),
                  let threeDimensionAxesEndRg = receivedData.range(of: Data([0x22, 0x7D]), in: threeDimensionAxesStartRg.upperBound..<receivedData.count) else { break }
            
            let threeDimensionAxesData = receivedData.subdata(in: threeDimensionAxesStartRg.lowerBound..<threeDimensionAxesEndRg.upperBound)
            
            if let threeDimensionAxes = parse3DAxes(from: threeDimensionAxesData) {
                setNeutralValues(roll: threeDimensionAxes.roll, pitch: threeDimensionAxes.pitch, yaw: threeDimensionAxes.yaw)
                applyRotation(axes: threeDimensionAxes)
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
              let dict = jsonObject as? [String: String],
              let roll = Double(dict["r"] ?? ""),
              let pitch = Double(dict["p"] ?? ""),
              let yaw = Double(dict["y"] ?? "") else { return nil }
        return ThreeDimension(pitch: CGFloat(pitch), roll: CGFloat(roll), yaw: CGFloat(yaw))
    }
    
    private func setNeutralValues(roll: CGFloat, pitch: CGFloat, yaw: CGFloat) {
        guard neutralRoll == nil, neutralPitch == nil, neutralYaw == nil else { return }
        neutralRoll = roll
        neutralPitch = pitch
        neutralYaw = yaw
    }
    
    private func applyRotation(axes: ThreeDimension) {
        guard let neutralRoll = neutralRoll, let neutralPitch = neutralPitch, let neutralYaw = neutralYaw else { return }
        
        let deltaRoll = axes.roll - neutralRoll
        let deltaPitch = axes.pitch - neutralPitch
        let deltaYaw = axes.yaw - neutralYaw
        
        UIView.animate(withDuration: 0.2) {
            var transform = CATransform3DIdentity
            transform.m34 = -1 / 500
            transform = CATransform3DRotate(transform, CGFloat(deltaRoll * .pi / 180), 0, 0, 1)
            transform = CATransform3DRotate(transform, CGFloat(deltaPitch * .pi / 180), 1, 0, 0)
            transform = CATransform3DRotate(transform, CGFloat(deltaYaw * .pi / 180), 0, 1, 0)
            self.imageView.layer.transform = transform
        }
    }
}
