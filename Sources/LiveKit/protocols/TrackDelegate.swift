import Foundation

#if !os(macOS)
import UIKit
#endif

// Currenlty used for internal purposes
public protocol TrackDelegate {
    func track(_ track: Track, didUpdate size: CGSize)
}

extension TrackDelegate {
    func track(_ track: Track, didUpdate size: CGSize) {}
}
