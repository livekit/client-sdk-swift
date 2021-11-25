import CoreMedia
import Foundation

public protocol AudioSink {
    func renderSample(audioSample: CMSampleBuffer)
}
