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

import Foundation
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

@objc
public protocol VideoCapturerDelegate: AnyObject {

    @objc(capturer:didUpdateDimensions:) optional
    func capturer(_ capturer: VideoCapturer, didUpdate dimensions: Dimensions?)

    @objc(capturer:didUpdateState:) optional
    func capturer(_ capturer: VideoCapturer, didUpdate state: VideoCapturer.CapturerState)
}

// Intended to be a base class for video capturers
public class VideoCapturer: NSObject, Loggable, VideoCapturerProtocol {

    // MARK: - MulticastDelegate

    private var delegates = MulticastDelegate<VideoCapturerDelegate>()

    internal let queue = DispatchQueue(label: "LiveKitSDK.videoCapturer", qos: .default)

    /// Array of supported pixel formats that can be used to capture a frame.
    ///
    /// Usually the following formats are supported but it is recommended to confirm at run-time:
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`,
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`,
    /// `kCVPixelFormatType_32BGRA`,
    /// `kCVPixelFormatType_32ARGB`.
    public static let supportedPixelFormats = DispatchQueue.webRTC.sync { RTCCVPixelBuffer.supportedPixelFormats() }

    public static func createTimeStampNs() -> Int64 {
        let systemTime = ProcessInfo.processInfo.systemUptime
        return Int64(systemTime * Double(NSEC_PER_SEC))
    }

    @objc
    public enum CapturerState: Int {
        case stopped
        case started
    }

    internal weak var delegate: RTCVideoCapturerDelegate?

    internal struct State {
        var dimensionsCompleter = Completer<Dimensions>()
    }

    internal var _state = StateSync(State())

    public internal(set) var dimensions: Dimensions? {
        didSet {
            guard oldValue != dimensions else { return }
            log("[publish] \(String(describing: oldValue)) -> \(String(describing: dimensions))")
            delegates.notify { $0.capturer?(self, didUpdate: self.dimensions) }

            log("[publish] dimensions: \(String(describing: dimensions))")
            _state.mutate { $0.dimensionsCompleter.set(value: dimensions) }
        }
    }

    public private(set) var captureState: CapturerState = .stopped

    init(delegate: RTCVideoCapturerDelegate) {
        self.delegate = delegate
    }

    deinit {
        assert(captureState == .stopped, "captureState is not .stopped, capturer must be stopped before deinit.")
    }

    // returns true if state updated
    public func startCapture() -> Promise<Bool> {

        Promise(on: queue) { () -> Bool in

            guard self.captureState != .started else {
                // already started
                return false
            }

            self.captureState = .started

            self.delegates.notify(label: { "capturer.didUpdate state: \(CapturerState.started)" }) {
                $0.capturer?(self, didUpdate: .started)
            }

            return true
        }
    }

    // returns true if state updated
    public func stopCapture() -> Promise<Bool> {

        Promise(on: queue) { () -> Bool in

            guard self.captureState != .stopped else {
                // already stopped
                return false
            }

            self.captureState = .stopped
            self.delegates.notify(label: { "capturer.didUpdate state: \(CapturerState.stopped)" }) {
                $0.capturer?(self, didUpdate: .stopped)
            }

            self._state.mutate { $0.dimensionsCompleter.reset() }

            return true
        }
    }

    public func restartCapture() -> Promise<Bool> {
        stopCapture().then(on: queue) { _ -> Promise<Bool> in
            self.startCapture()
        }
    }
}

// MARK: - MulticastDelegate

extension VideoCapturer: MulticastDelegateProtocol {

    @objc(addDelegate:)
    public func add(delegate: VideoCapturerDelegate) {
        delegates.add(delegate: delegate)
    }

    @objc(removeDelegate:)
    public func remove(delegate: VideoCapturerDelegate) {
        delegates.remove(delegate: delegate)
    }

    @objc
    public func removeAllDelegates() {
        delegates.removeAllDelegates()
    }
}
