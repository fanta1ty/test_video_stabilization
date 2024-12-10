//
//  ViewController.swift
//  testVideoStablize
//
//  Created by Thinh Nguyen on 10/12/24.
//

import UIKit
import MobileVLCKit

class ViewController: UIViewController {
    // Define the VLC media players
    private var originalPlayer: VLCMediaPlayer!
    private var renderedPlayer: VLCMediaPlayer!
    
    // Define the URLs for the streams
    private let originalStreamURL = "rtmp://192.168.50.181/live"
    private let renderedStreamURL = "rtmp://192.168.50.181/live" // Replace with rendered stream URL if different
    
    // Define the UIViews for the players
    private let originalPlayerView = UIView()
    private let renderedPlayerView = UIView()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupUI()
        setupPlayers()
        startStreaming()
    }
    
    private func setupUI() {
        // Set the background color
        view.backgroundColor = .black
        
        // Add and configure the player views
        originalPlayerView.translatesAutoresizingMaskIntoConstraints = false
        renderedPlayerView.translatesAutoresizingMaskIntoConstraints = false
        
        view.addSubview(originalPlayerView)
        view.addSubview(renderedPlayerView)
        
        // Layout for the player views
        NSLayoutConstraint.activate([
            // Original Player (top half of the screen)
            originalPlayerView.topAnchor.constraint(equalTo: view.topAnchor),
            originalPlayerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            originalPlayerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            originalPlayerView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5),
            
            // Rendered Player (bottom half of the screen)
            renderedPlayerView.topAnchor.constraint(equalTo: originalPlayerView.bottomAnchor),
            renderedPlayerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderedPlayerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            renderedPlayerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    private func setupPlayers() {
        // Initialize the VLC media players
        originalPlayer = VLCMediaPlayer()
        renderedPlayer = VLCMediaPlayer()
        
        // Assign the player views to the VLC media players
        originalPlayer.drawable = originalPlayerView
        renderedPlayer.drawable = renderedPlayerView
    }
    
    private func startStreaming() {
        // Set up media for the original stream
        if let originalMediaURL = URL(string: originalStreamURL) {
            let originalMedia = VLCMedia(url: originalMediaURL)
            originalPlayer.media = originalMedia
            originalPlayer.play()
        } else {
            print("Error: Invalid URL for the original stream.")
        }
        
        // Set up media for the rendered stream
        if let renderedMediaURL = URL(string: renderedStreamURL) {
            let renderedMedia = VLCMedia(url: renderedMediaURL)
            renderedPlayer.media = renderedMedia
            renderedPlayer.play()
        } else {
            print("Error: Invalid URL for the rendered stream.")
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop the players when the view is about to disappear
        originalPlayer.stop()
        renderedPlayer.stop()
    }
    
}

