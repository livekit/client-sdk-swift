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

@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
open class LocalMedia: ObservableObject {
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

    @Published public private(set) var error: Error?

    @Published public private(set) var microphoneTrack: (any AudioTrack)?
    @Published public private(set) var cameraTrack: (any VideoTrack)?
    @Published public private(set) var screenShareTrack: (any VideoTrack)?

    @Published public private(set) var isMicrophoneEnabled: Bool = false
    @Published public private(set) var isCameraEnabled: Bool = false
    @Published public private(set) var isScreenShareEnabled: Bool = false

    @Published public private(set) var audioDevices: [AudioDevice] = AudioManager.shared.inputDevices
    @Published public private(set) var selectedAudioDeviceID: String = AudioManager.shared.inputDevice.deviceId

    @Published public private(set) var videoDevices: [AVCaptureDevice] = []
    @Published public private(set) var selectedVideoDeviceID: String?

    @Published public private(set) var canSwitchCamera = false

    // MARK: - Dependencies

    private var localParticipant: LocalParticipant

    // MARK: - Initialization

    public init(localParticipant: LocalParticipant) {
        self.localParticipant = localParticipant

        observe(localParticipant)
        observeDevices()
    }

    public convenience init(room: Room) {
        self.init(localParticipant: room.localParticipant)
    }

    public convenience init(session: Session) {
        self.init(room: session.room)
    }

    private func observe(_ localParticipant: LocalParticipant) {
        Task { [weak self] in
            for try await _ in localParticipant.changes {
                guard let self else { return }

                microphoneTrack = localParticipant.firstAudioTrack
                cameraTrack = localParticipant.firstCameraVideoTrack
                screenShareTrack = localParticipant.firstScreenShareVideoTrack

                isMicrophoneEnabled = localParticipant.isMicrophoneEnabled()
                isCameraEnabled = localParticipant.isCameraEnabled()
                isScreenShareEnabled = localParticipant.isScreenShareEnabled()
            }
        }
    }

    private func observeDevices() {
        try? AudioManager.shared.set(microphoneMuteMode: .inputMixer) // don't play mute sound effect
        Task {
            try await AudioManager.shared.setRecordingAlwaysPreparedMode(true)
        }

        AudioManager.shared.onDeviceUpdate = { [weak self] _ in
            Task { @MainActor in
                self?.audioDevices = AudioManager.shared.inputDevices
                self?.selectedAudioDeviceID = AudioManager.shared.defaultInputDevice.deviceId
            }
        }

        Task {
            canSwitchCamera = try await CameraCapturer.canSwitchPosition()
            videoDevices = try await CameraCapturer.captureDevices()
            selectedVideoDeviceID = videoDevices.first?.uniqueID
        }
    }

    deinit {
        AudioManager.shared.onDeviceUpdate = nil
    }

    // MARK: - Toggle

    public func toggleMicrophone() async {
        do {
            try await localParticipant.setMicrophone(enabled: !isMicrophoneEnabled)
        } catch {
            self.error = .mediaDevice(error)
        }
    }

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

    public func select(audioDevice: AudioDevice) {
        selectedAudioDeviceID = audioDevice.deviceId

        let device = AudioManager.shared.inputDevices.first(where: { $0.deviceId == selectedAudioDeviceID }) ?? AudioManager.shared.defaultInputDevice
        AudioManager.shared.inputDevice = device
    }

    public func select(videoDevice: AVCaptureDevice) async {
        selectedVideoDeviceID = videoDevice.uniqueID

        guard let cameraCapturer = getCameraCapturer() else { return }
        let captureOptions = CameraCaptureOptions(device: videoDevice)
        _ = try? await cameraCapturer.set(options: captureOptions)
    }

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
