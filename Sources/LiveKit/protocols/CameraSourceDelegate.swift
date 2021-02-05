//
//  File.swift
//  
//
//  Created by Russell D'Sa on 1/31/21.
//

import Foundation
import AVFoundation

protocol CameraSourceDelegate: AnyObject {
    func cameraSourceInterruptionEnded(source: CameraSource)
    func cameraSourceWasInterrupted(source: CameraSource, reason: AVCaptureSession.InterruptionReason)
    func cameraSourceError(source: CameraSource, error: Error)
}
