//
//  UIImage+Ext.swift
//  testVideoStablize
//
//  Created by Thinh Nguyen on 18/12/24.
//

import Foundation
import UIKit
import AVKit
import Vision
import CoreImage

extension UIImage {
    func rotate(by radians: CGFloat) -> UIImage? {
        // Calculate the new size for the rotated image
        let newSize = CGRect(origin: .zero, size: self.size)
            .applying(CGAffineTransform(rotationAngle: radians))
            .integral.size

        // Create a new graphics context with the new size
        UIGraphicsBeginImageContextWithOptions(newSize, false, self.scale)
        guard let context = UIGraphicsGetCurrentContext() else { return nil }

        // Move the origin to the middle of the image to rotate around the center
        context.translateBy(x: newSize.width / 2, y: newSize.height / 2)

        // Apply the rotation
        context.rotate(by: radians)

        // Draw the original image at the rotated position
        self.draw(in: CGRect(x: -self.size.width / 2,
                             y: -self.size.height / 2,
                             width: self.size.width,
                             height: self.size.height))

        // Capture the rotated image
        let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()

        // Clean up the graphics context
        UIGraphicsEndImageContext()

        return rotatedImage
    }
    
    func rotateAndScaleToFit(by radians: CGFloat, targetSize: CGSize) -> UIImage? {
        // Calculate the new bounding box size after rotation
        let rotatedSize = CGRect(origin: .zero, size: self.size)
            .applying(CGAffineTransform(rotationAngle: radians))
            .integral.size
        
        // Calculate the scaling factor to fit the rotated image within the target size
        let scaleX = targetSize.width / rotatedSize.width
        let scaleY = targetSize.height / rotatedSize.height
        let scaleFactor = min(scaleX, scaleY) // Maintain aspect ratio
        
        // Create a new size with the scaling factor
        let scaledSize = CGSize(width: rotatedSize.width * scaleFactor,
                                height: rotatedSize.height * scaleFactor)
        
        // Begin image context with scaled size
        UIGraphicsBeginImageContextWithOptions(targetSize, false, self.scale)
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        // Move context origin to the center to rotate around the image center
        context.translateBy(x: targetSize.width / 2, y: targetSize.height / 2)
        
        // Apply rotation
        context.rotate(by: radians)
        
        // Draw the image at its scaled size
        self.draw(in: CGRect(x: -scaledSize.width / 2,
                             y: -scaledSize.height / 2,
                             width: scaledSize.width,
                             height: scaledSize.height))
        
        // Capture the rotated and scaled image
        let rotatedScaledImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return rotatedScaledImage
    }
}
