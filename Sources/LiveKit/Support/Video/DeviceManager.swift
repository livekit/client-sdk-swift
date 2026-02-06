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

public class DeviceManager: ObservableObject, @unchecked Sendable, Loggable {
    // MARK: - Public

    public static let shared = DeviceManager()

    public static func prepare() {
        // Instantiate shared instance
        _ = shared
    }

    // MARK: - Published Properties

    @Published public internal(set) var videoCaptureDevices: [VideoCaptureDevice] = []
    @Published public internal(set) var audioInputDevices: [AudioDevice] = []
    @Published public internal(set) var audioOutputDevices: [AudioDevice] = []

    @Published public internal(set) var selectedVideoCapture: VideoCaptureDevice?
    @Published public internal(set) var selectedAudioInput: AudioDevice?
    @Published public internal(set) var selectedAudioOutput: AudioDevice?

    @Published public internal(set) var error: (any Error)?

    // MARK: - Internal (video discovery)

    // Async version, waits until initial device fetch is complete
    func devices() async throws -> [AVCaptureDevice] {
        try await _devicesCompleter.wait()
    }

    // Sync version
    func devices() -> [AVCaptureDevice] {
        _state.devices
    }

    #if os(iOS) || os(macOS) || os(tvOS)
    private lazy var discoverySession: AVCaptureDevice.DiscoverySession = {
        var deviceTypes: [AVCaptureDevice.DeviceType]
        #if os(iOS) || os(tvOS)
        // In order of priority
        deviceTypes = [
            .builtInTripleCamera, // Virtual, switchOver: [2, 6], default: 2
            .builtInDualCamera, // Virtual, switchOver: [3], default: 1
            .builtInDualWideCamera, // Virtual, switchOver: [2], default: 2
            .builtInWideAngleCamera, // Physical, General purpose use
            .builtInTelephotoCamera, // Physical
            .builtInUltraWideCamera, // Physical
        ]
        #else
        deviceTypes = [
            .builtInWideAngleCamera,
        ]
        #endif

        // Xcode 15.0 Swift 5.9
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            deviceTypes.append(contentsOf: [
                .continuityCamera,
                .external,
            ])
        }

        return AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes,
                                                mediaType: .video,
                                                position: .unspecified)
    }()
    #endif

    private struct State {
        var devices: [AVCaptureDevice] = []
        var multiCamDeviceSets: [Set<AVCaptureDevice>] = []
    }

    private let _state = StateSync(State())

    private let _devicesCompleter = AsyncCompleter<[AVCaptureDevice]>(label: "devices", defaultTimeout: 10)
    private let _multiCamDeviceSetsCompleter = AsyncCompleter<[Set<AVCaptureDevice>]>(label: "multiCamDeviceSets", defaultTimeout: 10)

    private var _devicesObservation: NSKeyValueObservation?
    private var _multiCamDeviceSetsObservation: NSKeyValueObservation?

    /// Find multi-cam compatible devices.
    func multiCamCompatibleDevices(for devices: Set<AVCaptureDevice>) async throws -> [AVCaptureDevice] {
        let deviceSets = try await _multiCamDeviceSetsCompleter.wait()

        let compatibleDevices = deviceSets.filter { $0.isSuperset(of: devices) }
            .reduce(into: Set<AVCaptureDevice>()) { $0.formUnion($1) }
            .subtracting(devices)

        let devices = try await _devicesCompleter.wait()

        // This ensures the ordering is same as the devices array.
        return devices.filter { compatibleDevices.contains($0) }
    }

    init() {
        log()

        #if os(iOS) || os(macOS) || os(tvOS)
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            _devicesObservation = discoverySession.observe(\.devices, options: [.initial, .new]) { [weak self] _, value in
                guard let self else { return }
                let devices = (value.newValue ?? []).sortedByFacingPositionPriority()
                log("Devices: \(String(describing: devices))")
                _state.mutate { $0.devices = devices }
                _devicesCompleter.resume(returning: devices)
                #if os(macOS)
                _multiCamDeviceSetsCompleter.resume(returning: [])
                #endif
            }
        }
        #elseif os(visionOS)
        // For visionOS, there is no DiscoverySession so return the Persona camera if available.
        let devices: [AVCaptureDevice] = [.systemPreferredCamera].compactMap { $0 }
        _state.mutate { $0.devices = devices }
        _devicesCompleter.resume(returning: devices)
        _multiCamDeviceSetsCompleter.resume(returning: [])
        #endif

        #if os(iOS) || os(tvOS)
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            _multiCamDeviceSetsObservation = discoverySession.observe(\.supportedMultiCamDeviceSets, options: [.initial, .new]) { [weak self] _, value in
                guard let self else { return }
                let deviceSets = (value.newValue ?? [])
                log("MultiCam deviceSets: \(String(describing: deviceSets))")
                _state.mutate { $0.multiCamDeviceSets = deviceSets }
                _multiCamDeviceSetsCompleter.resume(returning: deviceSets)
            }
        }
        #endif

        // Wire video device observation
        _state.onDidMutate = { [weak self] newState, _ in
            let videoDevices = newState.devices.map { VideoCaptureDevice(avCaptureDevice: $0) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                videoCaptureDevices = videoDevices
                reconcileVideoSelection()
            }
        }

        // Wire audio device observation
        observeAudioDevices()
    }

    // MARK: - Audio Observation

    private func observeAudioDevices() {
        let existingCallback = AudioManager.shared.onDeviceUpdate

        AudioManager.shared.onDeviceUpdate = { [weak self] audioManager in
            let inputDevices = audioManager.inputDevices
            let outputDevices = audioManager.outputDevices
            let inputDevice = audioManager.inputDevice
            let outputDevice = audioManager.outputDevice

            Task { @MainActor [weak self] in
                guard let self else { return }
                audioInputDevices = inputDevices
                audioOutputDevices = outputDevices
                // Update selected if not yet set
                if selectedAudioInput == nil {
                    selectedAudioInput = inputDevice
                }
                if selectedAudioOutput == nil {
                    selectedAudioOutput = outputDevice
                }
                reconcileAudioSelection()
            }

            existingCallback?(audioManager)
        }

        // Initial population
        Task { @MainActor [weak self] in
            guard let self else { return }
            audioInputDevices = AudioManager.shared.inputDevices
            audioOutputDevices = AudioManager.shared.outputDevices
            selectedAudioInput = AudioManager.shared.inputDevice
            selectedAudioOutput = AudioManager.shared.outputDevice
        }
    }

    // MARK: - Reconciliation

    @MainActor
    func reconcileVideoSelection() {
        if let selected = selectedVideoCapture,
           !videoCaptureDevices.contains(where: { $0.deviceId == selected.deviceId })
        {
            selectedVideoCapture = videoCaptureDevices.first
        }
    }

    @MainActor
    func reconcileAudioSelection() {
        if let selected = selectedAudioInput,
           !audioInputDevices.contains(where: { $0.deviceId == selected.deviceId })
        {
            selectedAudioInput = audioInputDevices.first(where: \.isDefault)
        }
        if let selected = selectedAudioOutput,
           !audioOutputDevices.contains(where: { $0.deviceId == selected.deviceId })
        {
            selectedAudioOutput = audioOutputDevices.first(where: \.isDefault)
        }
    }

    // MARK: - Error

    @MainActor
    public func dismissError() {
        error = nil
    }
}

extension [AVCaptureDevice] {
    /// Sort priority: .front = 2, .back = 1, .unspecified = 3.
    func sortedByFacingPositionPriority() -> [Element] {
        sorted(by: { $0.facingPosition.rawValue > $1.facingPosition.rawValue })
    }
}
