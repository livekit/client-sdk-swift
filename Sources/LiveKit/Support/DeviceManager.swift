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

// Internal-only for now
class DeviceManager: @unchecked Sendable, Loggable {
    // MARK: - Public

    static let shared = DeviceManager()

    static func prepare() {
        // Instantiate shared instance
        _ = shared
    }

    // Async version, waits until inital device fetch is complete
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
    }
}

extension [AVCaptureDevice] {
    /// Sort priority: .front = 2, .back = 1, .unspecified = 3.
    func sortedByFacingPositionPriority() -> [Element] {
        sorted(by: { $0.facingPosition.rawValue > $1.facingPosition.rawValue })
    }
}
