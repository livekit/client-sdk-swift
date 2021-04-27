//
//  File.swift
//
//
//  Created by Russell D'Sa on 12/16/20.
//

import CoreMedia
import Foundation

public protocol AudioSink {
    func renderSample(audioSample: CMSampleBuffer)
}
