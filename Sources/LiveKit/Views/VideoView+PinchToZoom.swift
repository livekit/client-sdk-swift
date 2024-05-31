/*
 * Copyright 2024 LiveKit
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

@_implementationOnly import LiveKitWebRTC

extension VideoView {
    /// Options for pinch to zoom in / out feature.
    public struct PinchToZoomOptions: OptionSet {
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
        public static let autoReset = PinchToZoomOptions(rawValue: 1 << 2)
    }

    #if os(iOS) || os(visionOS)
    func _adjustAllowedZoomFactor() {
        guard let device = _currentDevice else { return }
        let options = _state.pinchToZoomOptions
        let currentZoomFactor = device.videoZoomFactor
        let zoomBounds = _computeZoomBounds(for: device, options: options)
        // Only update if out of bounds
        if !zoomBounds.contains(currentZoomFactor) {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                let newVideoZoomFactor = currentZoomFactor.clamped(to: zoomBounds)

                log("Setting videoZoomFactor to \(newVideoZoomFactor)")
                device.ramp(toVideoZoomFactor: newVideoZoomFactor, withRate: 32.0)
            } catch {
                log("Failed to adjust videoZoomFactor", .warning)
            }
        }
    }

    @objc func _handlePinchGesture(_ sender: UIPinchGestureRecognizer) {
        guard let device = _currentDevice else { return }

        if sender.state == .began {
            _pinchStartZoomFactor = device.videoZoomFactor
        } else {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                let options = _state.pinchToZoomOptions

                if sender.state == .changed {
                    let zoomBounds = _computeZoomBounds(for: device, options: options)
                    let newVideoZoomFactor = (_pinchStartZoomFactor * sender.scale).clamped(to: zoomBounds)

                    log("Setting videoZoomFactor to \(newVideoZoomFactor)")
                    device.videoZoomFactor = newVideoZoomFactor
                } else if sender.state == .ended || sender.state == .cancelled, options.contains(.autoReset) {
                    let defaultZoomFactor = LKRTCCameraVideoCapturer.defaultZoomFactor(forDeviceType: device.deviceType)
                    device.ramp(toVideoZoomFactor: defaultZoomFactor, withRate: 32.0)
                }
            } catch {
                log("Failed to adjust videoZoomFactor", .warning)
            }
        }
    }

    private var _currentDevice: AVCaptureDevice? {
        guard let track = _state.track as? LocalVideoTrack,
              let capturer = track.capturer as? CameraCapturer else { return nil }
        return capturer.device
    }

    private func _computeZoomBounds(for device: AVCaptureDevice, options: PinchToZoomOptions) -> ClosedRange<CGFloat> {
        let defaultZoomFactor = LKRTCCameraVideoCapturer.defaultZoomFactor(forDeviceType: device.deviceType)

        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = device.maxAvailableVideoZoomFactor

        let clampedMinZoom = options.contains(.zoomOut) ? minZoom : max(defaultZoomFactor, minZoom)
        let clampedMaxZoom = options.contains(.zoomIn) ? maxZoom : min(defaultZoomFactor, maxZoom)

        return clampedMinZoom ... clampedMaxZoom
    }

    #endif
}
