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
import Combine
import Foundation

/// An ``ObservableObject`` that can be used to control the local participant's media devices.
///
/// This class provides a convenient way to manage local media tracks, including enabling/disabling
/// microphone and camera, and selecting audio and video devices. It is designed to be used
/// in SwiftUI views.
@MainActor
open class LocalMedia: ObservableObject, Loggable {
    // MARK: - Error

    public enum Error: LocalizedError {
        case mediaDevice(Swift.Error)

        public var errorDescription: String? {
            switch self {
            case let .mediaDevice(error):
                "Media device error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Devices

    /// The last error that occurred.
    @Published public private(set) var error: Error?

    /// The local microphone track.
    @Published public private(set) var microphoneTrack: (any AudioTrack)?
    /// The local camera track.
    @Published public private(set) var cameraTrack: (any VideoTrack)?
    /// The local screen share track.
    @Published public private(set) var screenShareTrack: (any VideoTrack)?

    /// A boolean value indicating whether the microphone is enabled.
    @Published public private(set) var isMicrophoneEnabled: Bool = false
    /// A boolean value indicating whether the camera is enabled.
    @Published public private(set) var isCameraEnabled: Bool = false
    /// A boolean value indicating whether screen sharing is enabled.
    @Published public private(set) var isScreenShareEnabled: Bool = false

    /// The available audio input devices.
    @Published public private(set) var audioDevices: [AudioDevice] = AudioManager.shared.inputDevices
    /// The ID of the selected audio input device.
    @Published public private(set) var selectedAudioDeviceID: String = AudioManager.shared.inputDevice.deviceId

    /// The available video capture devices.
    @Published public private(set) var videoDevices: [AVCaptureDevice] = []
    /// The ID of the selected video capture device.
    @Published public private(set) var selectedVideoDeviceID: String?

    /// A boolean value indicating whether the camera position can be switched.
    @Published public private(set) var canSwitchCamera = false

    // MARK: - Dependencies

    private var localParticipant: LocalParticipant
    private var tasks = Set<AnyTaskCancellable>()

    // MARK: - Initialization

    /// Initializes a new ``LocalMedia`` object.
    /// - Parameter localParticipant: The ``LocalParticipant`` to control.
    public init(localParticipant: LocalParticipant) {
        self.localParticipant = localParticipant

        observe(localParticipant)
        observeDevices()
    }

    /// Initializes a new ``LocalMedia`` object.
    /// - Parameter room: The ``Room`` to control.
    public convenience init(room: Room) {
        self.init(localParticipant: room.localParticipant)
    }

    /// Initializes a new ``LocalMedia`` object.
    /// - Parameter session: The ``Session`` to control.
    public convenience init(session: Session) {
        self.init(room: session.room)
    }

    private func observe(_ localParticipant: LocalParticipant) {
        localParticipant.changes.subscribeOnMainActor(self) { observer, _ in
            observer.microphoneTrack = localParticipant.firstAudioTrack
            observer.cameraTrack = localParticipant.firstCameraVideoTrack
            observer.screenShareTrack = localParticipant.firstScreenShareVideoTrack

            observer.isMicrophoneEnabled = localParticipant.isMicrophoneEnabled()
            observer.isCameraEnabled = localParticipant.isCameraEnabled()
            observer.isScreenShareEnabled = localParticipant.isScreenShareEnabled()
        }.store(in: &tasks)
    }

    private func observeDevices() {
        try? AudioManager.shared.set(microphoneMuteMode: .inputMixer) // don't play mute sound effect
        Task {
            do {
                try await AudioManager.shared.setRecordingAlwaysPreparedMode(true)
            } catch {
                log("Failed to setRecordingAlwaysPreparedMode: \(error)", .error)
            }
        }

        AudioManager.shared.onDeviceUpdate = { _ in
            Task { @MainActor [weak self] in
                self?.audioDevices = AudioManager.shared.inputDevices
                self?.selectedAudioDeviceID = AudioManager.shared.defaultInputDevice.deviceId
            }
        }

        Task {
            do {
                canSwitchCamera = try await CameraCapturer.canSwitchPosition()
                videoDevices = try await CameraCapturer.captureDevices()
                selectedVideoDeviceID = videoDevices.first?.uniqueID
            } catch {
                log("Failed to configure camera devices: \(error)", .error)
            }
        }
    }

    deinit {
        AudioManager.shared.onDeviceUpdate = nil
    }

    /// Resets the last error.
    public func dismissError() {
        error = nil
    }

    // MARK: - Toggle

    /// Toggles the microphone on or off.
    public func toggleMicrophone() async {
        do {
            try await localParticipant.setMicrophone(enabled: !isMicrophoneEnabled)
        } catch {
            self.error = .mediaDevice(error)
        }
    }

    /// Toggles the camera on or off.
    /// - Parameter disableScreenShare: If `true`, screen sharing will be disabled when the camera is enabled.
    public func toggleCamera(disableScreenShare: Bool = false) async {
        let enable = !isCameraEnabled
        do {
            if enable, disableScreenShare, isScreenShareEnabled {
                try await localParticipant.setScreenShare(enabled: false)
            }

            let device = try await CameraCapturer.captureDevices().first(where: { $0.uniqueID == selectedVideoDeviceID })
            try await localParticipant.setCamera(enabled: enable, captureOptions: CameraCaptureOptions(device: device))
        } catch {
            self.error = .mediaDevice(error)
        }
    }

    /// Toggles screen sharing on or off.
    /// - Parameter disableCamera: If `true`, the camera will be disabled when screen sharing is enabled.
    public func toggleScreenShare(disableCamera: Bool = false) async {
        let enable = !isScreenShareEnabled
        do {
            if enable, disableCamera, isCameraEnabled {
                try await localParticipant.setCamera(enabled: false)
            }
            try await localParticipant.setScreenShare(enabled: enable)
        } catch {
            self.error = .mediaDevice(error)
        }
    }

    // MARK: - Select

    /// Selects an audio input device.
    /// - Parameter audioDevice: The ``AudioDevice`` to select.
    public func select(audioDevice: AudioDevice) {
        selectedAudioDeviceID = audioDevice.deviceId

        let device = AudioManager.shared.inputDevices.first(where: { $0.deviceId == selectedAudioDeviceID }) ?? AudioManager.shared.defaultInputDevice
        AudioManager.shared.inputDevice = device
    }

    /// Selects a video capture device.
    /// - Parameter videoDevice: The ``AVCaptureDevice`` to select.
    public func select(videoDevice: AVCaptureDevice) async {
        guard let cameraCapturer = getCameraCapturer() else { return }
        do {
            try await cameraCapturer.set(options: .init(device: videoDevice))
            selectedVideoDeviceID = videoDevice.uniqueID
        } catch {
            self.error = .mediaDevice(error)
        }
    }

    /// Switches the camera position.
    public func switchCamera() async {
        guard let cameraCapturer = getCameraCapturer() else { return }
        _ = try? await cameraCapturer.switchCameraPosition()
    }

    // MARK: - Private

    private func getCameraCapturer() -> CameraCapturer? {
        guard let cameraTrack = localParticipant.firstCameraVideoTrack as? LocalVideoTrack else { return nil }
        return cameraTrack.capturer as? CameraCapturer
    }
}
