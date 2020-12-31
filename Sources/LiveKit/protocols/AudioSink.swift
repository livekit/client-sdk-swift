//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/16/20.
//

import Foundation
import CoreMedia

public protocol AudioSink {
    func renderSample(audioSample: CMSampleBuffer)
}
