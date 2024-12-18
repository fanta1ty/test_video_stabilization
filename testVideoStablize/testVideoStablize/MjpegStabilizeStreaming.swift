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
    
    fileprivate var receivedData = Data()
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
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            onError?(NSError(domain: "Invalid Response", code: -1, userInfo: nil))
            completionHandler(.cancel)
            return
        }

        if status == .loading {
            status = .playing
            DispatchQueue.main.async { self.didFinishLoading?() }
        }
        
        if let image = UIImage(data: receivedData) {
            processingQueue.async { [weak self] in
                guard let self = self else { return }
                self.semaphore.wait()
                self.frameBuffer.append(image)

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
        }
        receivedData = Data()
        completionHandler(.allow)
    }

    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
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
}
