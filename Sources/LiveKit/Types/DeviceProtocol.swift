/*
 * Copyright 2026 LiveKit
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

@preconcurrency import AVFoundation

/// A device that can capture or output media.
public protocol DeviceProtocol: Identifiable, Hashable, Sendable {
    var deviceId: String { get }
    var name: String { get }
}

public extension DeviceProtocol {
    var id: String { deviceId }
}

// MARK: - CameraPosition

/// The facing position of a camera device.
public enum CameraPosition: String, Sendable, CaseIterable {
    case front
    case back
    case unspecified

    init(from position: AVCaptureDevice.Position) {
        switch position {
        case .front: self = .front
        case .back: self = .back
        default: self = .unspecified
        }
    }
}

// MARK: - VideoCaptureDevice

/// A video capture device (camera).
public struct VideoCaptureDevice: DeviceProtocol {
    public let deviceId: String
    public let name: String
    public let position: CameraPosition

    /// Internal — used to bridge to CameraCaptureOptions.
    let _avCaptureDevice: AVCaptureDevice

    init(avCaptureDevice: AVCaptureDevice) {
        deviceId = avCaptureDevice.uniqueID
        name = avCaptureDevice.localizedName
        position = CameraPosition(from: avCaptureDevice.facingPosition)
        _avCaptureDevice = avCaptureDevice
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(deviceId)
    }

    public static func == (lhs: VideoCaptureDevice, rhs: VideoCaptureDevice) -> Bool {
        lhs.deviceId == rhs.deviceId
    }
}
