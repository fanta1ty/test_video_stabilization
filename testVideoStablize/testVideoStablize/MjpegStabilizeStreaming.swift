//
//  MjpegStabilizeStreaming.swift
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

class MjpegStabilizeStreaming: NSObject, URLSessionDataDelegate {
    
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
    
    private var imageData = Data()
    
    private let imageStabilizer = ImageStabilizer()
    private let imageStabilizerWrapper = ImageStabilizerWrapper()
    
    private var frameBuffer = [UIImage]() // Collect frames here
    private let frameBufferLimit = 3
    private let queue = DispatchQueue(label: "com.mjpegstreamingcontroller.frames") // Ensure thread-safety
    private var isProcessingFrames = false
    
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
        
        if let imageData = receivedData , imageData.length > 0,
            let receivedImage = UIImage(data: imageData as Data) {
            
            // I'm creating the UIImage before performing didFinishLoading to minimize the interval
            // between the actions done by didFinishLoading and the appearance of the first image
            if status == .loading {
                status = .playing
                DispatchQueue.main.async { self.didFinishLoading?() }
            }
            
            queue.async { [weak self] in
                guard let self else { return }
                self.frameBuffer.append(receivedImage)
                
                if self.frameBuffer.count == self.frameBufferLimit {
                    guard !self.isProcessingFrames else { return }
                    self.isProcessingFrames = true
                    
                    DispatchQueue.global(qos: .userInitiated).async {
                        let stabilizedImages = self.imageStabilizer.stabilized(withImageList: self.frameBuffer)
                        self.frameBuffer.removeAll()
                        
                        // Display stabilized images on the main thread
                        DispatchQueue.main.async {
                            self.isProcessingFrames = false
                            
                            stabilizedImages?.forEach({
                                self.imageView.image = $0 as? UIImage
                            })
                        }
                    }
                }
            }
        }
        
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
}
