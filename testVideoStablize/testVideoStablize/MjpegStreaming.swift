//
//  MjpegStreaming.swift
//  testVideoStablize
//
//  Created by Thinh Nguyen on 18/12/24.
//

import Foundation
import UIKit
import AVKit
import Vision
import CoreImage
import opencv2

class MjpegStreaming: NSObject, URLSessionDataDelegate {
    
    fileprivate enum Status {
        case stopped
        case loading
        case playing
    }
    
    fileprivate var receivedData: NSMutableData?
    fileprivate var dataTask: URLSessionDataTask?
    fileprivate var session: Foundation.URLSession!
    fileprivate var status: Status = .stopped
    let boundary = "--boundary\r\n"
    private var buffer = Data()
    private var frameNumber = 0
    
    open var authenticationHandler: ((URLAuthenticationChallenge) -> (Foundation.URLSession.AuthChallengeDisposition, URLCredential?))?
    open var didStartLoading: (()->Void)?
    open var didFinishLoading: (()->Void)?
    open var contentURL: URL?
    open var imageView: UIImageView
    
    private var imageData = Data()
    
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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        dataTask = session.dataTask(with: request)
        dataTask?.resume()
    }
    
    open func stop(){
        status = .stopped
        dataTask?.cancel()
    }
    
    // MARK: - NSURLSessionDataDelegate
    
    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        
//        if let httpResponse = response as? HTTPURLResponse  {
//            let headers = httpResponse.allHeaderFields
//            print("header: \(headers["rotateX"]) - Date: \(Date().timeIntervalSince1970)")
//        }
//        
//    
//        if let imageData = receivedData , imageData.length > 0,
//            let receivedImage = UIImage(data: imageData as Data) {
//            
//            // I'm creating the UIImage before performing didFinishLoading to minimize the interval
//            // between the actions done by didFinishLoading and the appearance of the first image
//            if status == .loading {
//                status = .playing
//                DispatchQueue.main.async { self.didFinishLoading?() }
//            }
//            
//            DispatchQueue.main.async { [weak self] in
//                guard let self = self else { return }
//                
//                guard let httpResponse = response as? HTTPURLResponse else {
//                    return
//                }
//                
////                let headers = httpResponse.allHeaderFields
////                print("header: \(headers["rotateX"])")
////                if let rotateXString = headers["rotateX"] as? String,
////                   let rotateX = Double(rotateXString) {
////                    // print("rotateX: \(rotateXString)")
////                    // Convert the angle from degrees to radians if needed
////                    let radians = CGFloat(rotateX) * .pi / 180
////                    
////                    // Rotate and scale the image to fit the imageView bounds
////                    if let newImage = receivedImage.rotateAndScaleToFit(by: radians, targetSize: self.imageView.bounds.size) {
////                        self.imageView.image = newImage
////                    } else {
////                        self.imageView.image = receivedImage // Fallback
////                    }
////                } else {
////                    self.imageView.image = receivedImage
////                }
//                self.imageView.image = receivedImage
//            }
//        }
        
        receivedData = NSMutableData()
        completionHandler(.allow)
    }
    
    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if data.count == 16, data.starts(with: Data([0x7b, 0x22])) && data.suffix(2) == Data([0x22, 0x7d]) {
            if let jsonString = String(data: data, encoding: .utf8) {
                print("JSON Data: \(jsonString)")
            }
        } else {
            buffer.append(data)
        }
        
//        print("Raw Buffer: \(String(data: data, encoding: .ascii))")
        
        processBuffer()
        
//        if buffer.count > boundary.count {
//            buffer = buffer.suffix(boundary.count)
//        }
        
        receivedData?.append(data)
    }
    
    func processBuffer() {
        //print(buffer.map { String(format: "%02x", $0) }.joined(separator: " "))

        while let imageStart = buffer.range(of: Data([0xff, 0xd8])),
              let imageEnd = buffer.range(of: Data([0xff, 0xd9]), in: imageStart.lowerBound..<buffer.endIndex) {
            let jpg = buffer.subdata(in: imageStart.lowerBound..<imageEnd.upperBound)
            buffer.removeSubrange(0..<imageEnd.upperBound)
            
            if let image = UIImage(data: jpg) {
                if status == .loading {
                    status = .playing
                    DispatchQueue.main.async { self.didFinishLoading?() }
                }
                
                DispatchQueue.main.async {
                    self.imageView.image = image
                }
            }
        }
    }
    
    func detectBoundary(from buffer: Data) -> String? {
        if let boundaryLine = String(data: buffer, encoding: .utf8)?.components(separatedBy: "\r\n").first(where: { $0.contains("--") }) {
            return boundaryLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
    
    func processFrame(_ frame: Data) {
        // Handle JSON Data
        if let jsonStart = frame.range(of: "Content-Type: application/json".data(using: .utf8)!) {
            let jsonData = frame.suffix(from: jsonStart.upperBound)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print("JSON Data: \(jsonString)")
            }
        }
        
        // Handle JPEG Images
        if let imageStart = frame.range(of: Data([0xff, 0xd8])),
           let imageEnd = frame.range(of: Data([0xff, 0xd9])) {
            let jpg = frame.subdata(in: imageStart.lowerBound..<imageEnd.upperBound + 2)
            if let image = UIImage(data: jpg) {
                frameNumber += 1
                let fileName = "frame_\(frameNumber).jpg"
                
                print("Saved: \(fileName)")
            }
        }
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
}
