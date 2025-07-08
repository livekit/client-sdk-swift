/*
 * Copyright 2025 LiveKit
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

internal import LiveKitWebRTC

extension VideoView {
    static let rampRate: Float = 32.0
    /// Options for pinch to zoom in / out feature.
    public struct PinchToZoomOptions: OptionSet, Sendable {
        public let rawValue: UInt

        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }

        public var isEnabled: Bool {
            contains(.zoomIn) || contains(.zoomOut)
        }

        /// Allow zooming in beyond the default zoom factor if supported by device.
        public static let zoomIn = PinchToZoomOptions(rawValue: 1 << 0)
        /// Allow zooming out beyond the default zoom factor if supported by device.
        public static let zoomOut = PinchToZoomOptions(rawValue: 1 << 1)
        /// Auto reset to default zoom level when pinch is released.
        public static let resetOnRelease = PinchToZoomOptions(rawValue: 1 << 2)
    }

    #if os(iOS)
    func _rampZoomFactorToAllowedBounds(options: PinchToZoomOptions) {
        guard let device = _currentCaptureDevice else { return }

        let currentZoomFactor = device.videoZoomFactor
        let zoomBounds = _computeAllowedZoomBounds(for: device, options: options)
        let defaultZoomFactor = LKRTCCameraVideoCapturer.defaultZoomFactor(forDeviceType: device.deviceType)
        let newVideoZoomFactor = options.contains(.resetOnRelease) ? defaultZoomFactor : currentZoomFactor.clamped(to: zoomBounds)

        guard currentZoomFactor != newVideoZoomFactor else { return }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            log("Setting videoZoomFactor to \(newVideoZoomFactor)")
            device.ramp(toVideoZoomFactor: newVideoZoomFactor, withRate: Self.rampRate)
        } catch {
            log("Failed to adjust videoZoomFactor", .warning)
        }
    }

    @objc func _handlePinchGesture(_ sender: UIPinchGestureRecognizer) {
        guard let device = _currentCaptureDevice else { return }

        if sender.state == .began {
            _pinchStartZoomFactor = device.videoZoomFactor
        } else {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                let options = _state.pinchToZoomOptions
                let zoomBounds = _computeAllowedZoomBounds(for: device, options: options)

                switch sender.state {
                case .changed:
                    let newVideoZoomFactor = (_pinchStartZoomFactor * sender.scale).clamped(to: zoomBounds)
                    log("Setting videoZoomFactor to \(newVideoZoomFactor)")
                    device.videoZoomFactor = newVideoZoomFactor
                case .ended, .cancelled:
                    if options.contains(.resetOnRelease) {
                        let defaultZoomFactor = LKRTCCameraVideoCapturer.defaultZoomFactor(forDeviceType: device.deviceType)
                        device.ramp(toVideoZoomFactor: defaultZoomFactor, withRate: Self.rampRate)
                    }
                default:
                    break
                }
            } catch {
                log("Failed to adjust videoZoomFactor", .warning)
            }
        }
    }

    // MARK: - Private

    private var _currentCaptureDevice: AVCaptureDevice? {
        guard let track = _state.track as? LocalVideoTrack,
              let capturer = track.capturer as? CameraCapturer else { return nil }

        return capturer.device
    }

    private func _computeAllowedZoomBounds(for device: AVCaptureDevice, options: PinchToZoomOptions) -> ClosedRange<CGFloat> {
        let defaultZoomFactor = LKRTCCameraVideoCapturer.defaultZoomFactor(forDeviceType: device.deviceType)

        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = device.maxAvailableVideoZoomFactor

        let lowerBound = options.contains(.zoomOut) ? minZoom : max(defaultZoomFactor, minZoom)
        let upperBound = options.contains(.zoomIn) ? maxZoom : min(defaultZoomFactor, maxZoom)

        return lowerBound ... upperBound
    }
    #endif
}
