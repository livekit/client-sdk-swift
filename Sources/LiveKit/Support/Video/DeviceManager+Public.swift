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

import SwiftUI

// MARK: - Computed Helpers

public extension DeviceManager {
    @MainActor
    var defaultAudioInput: AudioDevice? {
        audioInputDevices.first(where: \.isDefault)
    }

    @MainActor
    var defaultAudioOutput: AudioDevice? {
        audioOutputDevices.first(where: \.isDefault)
    }

    @MainActor
    var canSwitchCameraPosition: Bool {
        videoCaptureDevices.contains(where: { $0.position == .front }) &&
            videoCaptureDevices.contains(where: { $0.position == .back })
    }
}

// MARK: - Selection (imperative)

public extension DeviceManager {
    @MainActor
    func select(audioInput: AudioDevice) {
        selectedAudioInput = audioInput
        AudioManager.shared.inputDevice = audioInput
    }

    @MainActor
    func select(audioOutput: AudioDevice) {
        selectedAudioOutput = audioOutput
        AudioManager.shared.outputDevice = audioOutput
    }

    @MainActor
    func select(videoCapture: VideoCaptureDevice) {
        selectedVideoCapture = videoCapture
    }

    @MainActor
    func selectCamera(position: CameraPosition) {
        selectedVideoCapture = videoCaptureDevices.first(where: { $0.position == position })
    }

    @MainActor
    func switchCameraPosition() {
        let current = selectedVideoCapture?.position ?? .front
        selectCamera(position: current == .front ? .back : .front)
    }
}

// MARK: - Selection by ID (for persistence/restoration)

public extension DeviceManager {
    @MainActor
    @discardableResult
    func selectAudioInput(byId deviceId: String) -> Bool {
        guard let device = audioInputDevices.first(where: { $0.deviceId == deviceId }) else {
            return false
        }
        select(audioInput: device)
        return true
    }

    @MainActor
    @discardableResult
    func selectAudioOutput(byId deviceId: String) -> Bool {
        guard let device = audioOutputDevices.first(where: { $0.deviceId == deviceId }) else {
            return false
        }
        select(audioOutput: device)
        return true
    }

    @MainActor
    @discardableResult
    func selectVideoCapture(byId deviceId: String) -> Bool {
        guard let device = videoCaptureDevices.first(where: { $0.deviceId == deviceId }) else {
            return false
        }
        select(videoCapture: device)
        return true
    }
}

// MARK: - SwiftUI Bindings

public extension DeviceManager {
    @MainActor
    var audioInputBinding: Binding<AudioDevice?> {
        Binding(
            get: { self.selectedAudioInput },
            set: { newDevice in
                if let newDevice {
                    self.select(audioInput: newDevice)
                } else {
                    self.selectedAudioInput = nil
                }
            }
        )
    }

    @MainActor
    var audioOutputBinding: Binding<AudioDevice?> {
        Binding(
            get: { self.selectedAudioOutput },
            set: { newDevice in
                if let newDevice {
                    self.select(audioOutput: newDevice)
                } else {
                    self.selectedAudioOutput = nil
                }
            }
        )
    }

    @MainActor
    var videoCaptureBinding: Binding<VideoCaptureDevice?> {
        Binding(
            get: { self.selectedVideoCapture },
            set: { newDevice in
                if let newDevice {
                    self.select(videoCapture: newDevice)
                } else {
                    self.selectedVideoCapture = nil
                }
            }
        )
    }

    @MainActor
    var cameraPositionBinding: Binding<CameraPosition> {
        Binding(
            get: { self.selectedVideoCapture?.position ?? .unspecified },
            set: { newPosition in
                self.selectCamera(position: newPosition)
            }
        )
    }
}
