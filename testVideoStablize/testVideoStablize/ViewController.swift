import UIKit
import AVKit

class ViewController: UIViewController {
    var imageView: UIImageView = .init(frame: .zero)
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
                imageView.backgroundColor = .lightGray
        
        // Set constraints for imageView
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),  // 20 points from top
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),             // 20 points from left
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),          // 20 points from right
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor)                          // Square aspect ratio
        ])
        
        let streamURL = URL(string: "http://192.168.1.6:81/stream")!
        let mjpegStreamView = MjpegStreamingController(imageView: imageView)
        mjpegStreamView.contentURL = streamURL
        mjpegStreamView.play()
    }
    
}

class MjpegStreamingController: NSObject, URLSessionDataDelegate {
    
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
        if let httpResponse = response as? HTTPURLResponse {
            let headers = httpResponse.allHeaderFields
            print("Headers: \(headers)")
        }
        
        if let imageData = receivedData , imageData.length > 0,
            let receivedImage = UIImage(data: imageData as Data) {
            // I'm creating the UIImage before performing didFinishLoading to minimize the interval
            // between the actions done by didFinishLoading and the appearance of the first image
            if status == .loading {
                status = .playing
                DispatchQueue.main.async { self.didFinishLoading?() }
            }
            
            DispatchQueue.main.async {
                self.imageView.image = receivedImage
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
