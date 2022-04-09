/*
 * Copyright 2022 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import WebRTC
import Promises

public protocol VideoCapturerProtocol {
    var capturer: RTCVideoCapturer { get }
}

extension VideoCapturerProtocol {

    public var capturer: RTCVideoCapturer {
        fatalError("Must be implemented")
    }
}

public protocol VideoCapturerDelegate: AnyObject {
    func capturer(_ capturer: VideoCapturer, didUpdate dimensions: Dimensions?)
    func capturer(_ capturer: VideoCapturer, didUpdate state: VideoCapturer.State)
}

public extension VideoCapturerDelegate {
    func capturer(_ capturer: VideoCapturer, didUpdate dimensions: Dimensions?) {}
    func capturer(_ capturer: VideoCapturer, didUpdate state: VideoCapturer.State) {}
}

// MARK: - Closures

class VideoCapturerDelegateClosures: NSObject, VideoCapturerDelegate, Loggable {

    typealias DidUpdateDimensions = (VideoCapturer, Dimensions?) -> Void

    let didUpdateDimensions: DidUpdateDimensions?

    init(didUpdateDimensions: DidUpdateDimensions? = nil) {
        self.didUpdateDimensions = didUpdateDimensions
        super.init()
        log()
    }

    deinit {
        log()
    }

    func capturer(_ capturer: VideoCapturer, didUpdate dimensions: Dimensions?) {
        didUpdateDimensions?(capturer, dimensions)
    }
}

internal extension VideoCapturer {

    func waitForDimensions(allowCurrent: Bool = true) -> WaitPromises<Void> {

        if allowCurrent, dimensions != nil {
            return (Promise(()), { Promise(()) })
        }

        let listen = Promise<Void>.pending()
        let wait = Promise<Void>(on: .sdk) { resolve, _ in
            // create temporary delegate
            var delegate: VideoCapturerDelegateClosures?
            delegate = VideoCapturerDelegateClosures(didUpdateDimensions: { _, _ in
                // wait until connected
                resolve(())
                self.log("Dimensions resolved...")
                delegate = nil
            })
            // not required to clean up since weak reference
            self.add(delegate: delegate!)
            self.log("Waiting for dimensions...")

            self.log("[wait] listening for dimensions resolve...")
            listen.fulfill(())
        }

        let waitFunc = { () -> Promise<Void> in
            self.log("[wait] waiting for dimensions resolve...")
            return wait.timeout(.defaultCaptureStart)
        }

        // convert to a timed-promise only after called
        return (listen, waitFunc)
    }
}

// Intended to be a base class for video capturers
public class VideoCapturer: MulticastDelegate<VideoCapturerDelegate>, VideoCapturerProtocol {

    /// Array of supported pixel formats that can be used to capture a frame.
    ///
    /// Usually the following formats are supported but it is recommended to confirm at run-time:
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`,
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`,
    /// `kCVPixelFormatType_32BGRA`,
    /// `kCVPixelFormatType_32ARGB`.
    public static let supportedPixelFormats = DispatchQueue.webRTC.sync { RTCCVPixelBuffer.supportedPixelFormats() }

    public enum State {
        case stopped
        case started
    }

    internal weak var delegate: RTCVideoCapturerDelegate?

    public internal(set) var dimensions: Dimensions? {
        didSet {
            guard oldValue != dimensions else { return }
            log("\(String(describing: oldValue)) -> \(String(describing: dimensions))")
            notify { $0.capturer(self, didUpdate: self.dimensions) }
        }
    }

    public private(set) var state: State = .stopped

    init(delegate: RTCVideoCapturerDelegate) {
        self.delegate = delegate
    }

    // returns true if state updated
    public func startCapture() -> Promise<Bool> {

        Promise(on: .sdk) { () -> Bool in

            guard self.state != .started else {
                // already started
                return false
            }

            self.state = .started
            self.notify { $0.capturer(self, didUpdate: .started) }
            return true
        }
    }

    // returns true if state updated
    public func stopCapture() -> Promise<Bool> {

        Promise(on: .sdk) { () -> Bool in

            guard self.state != .stopped else {
                // already stopped
                return false
            }

            self.state = .stopped
            self.notify { $0.capturer(self, didUpdate: .stopped) }
            return true
        }
    }

    public func restartCapture() -> Promise<Bool> {
        stopCapture().then(on: .sdk) { _ -> Promise<Bool> in
            self.startCapture()
        }
    }
}
