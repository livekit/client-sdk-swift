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

import AVFoundation

// Internal-only for now
class DeviceManager: Loggable {
    // MARK: - Public

    #if compiler(>=6.0)
    public nonisolated(unsafe) static let shared = DeviceManager()
    #else
    public static let shared = DeviceManager()
    #endif

    public static func prepare() {
        // Instantiate shared instance
        _ = shared
    }

    // Async version, waits until inital device fetch is complete
    public func devices() async throws -> [AVCaptureDevice] {
        try await devicesCompleter.wait()
    }

    // Sync version
    public func devices() -> [AVCaptureDevice] {
        _state.devices
    }

    private lazy var discoverySession: AVCaptureDevice.DiscoverySession = {
        var deviceTypes: [AVCaptureDevice.DeviceType]
        #if os(iOS)
        // In order of priority
        deviceTypes = [
            .builtInTripleCamera, // Virtual, switchOver: [2, 6], default: 2
            .builtInDualCamera, // Virtual, switchOver: [3], default: 1
            .builtInDualWideCamera, // Virtual, switchOver: [2], default: 2
            .builtInWideAngleCamera, // Physical, General purpose use
            .builtInTelephotoCamera, // Physical
            .builtInUltraWideCamera, // Physical
        ]
        #elseif os(macOS)
        deviceTypes = [
            .builtInWideAngleCamera,
        ]
        #endif

        // Xcode 15.0 Swift 5.9 (iOS 17)
        #if compiler(>=5.9)
        if #available(macOS 14.0, iOS 17.0, *) {
            deviceTypes.append(contentsOf: [
                .continuityCamera,
                .external,
            ])
        }
        #endif

        return AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes,
                                                mediaType: .video,
                                                position: .unspecified)
    }()

    private struct State {
        var devices: [AVCaptureDevice] = []
    }

    private let _state = StateSync(State())

    private let devicesCompleter = AsyncCompleter<[AVCaptureDevice]>(label: "devices", defaultTimeout: 10)

    private var _observation: NSKeyValueObservation?

    init() {
        log()

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            self._observation = self.discoverySession.observe(\.devices, options: [.initial, .new]) { [weak self] _, value in
                guard let self else { return }
                // Sort priority: .front = 2, .back = 1, .unspecified = 3
                let devices = (value.newValue ?? []).sorted(by: { $0.position.rawValue > $1.position.rawValue })
                self.log("Devices: \(String(describing: devices))")
                self._state.mutate { $0.devices = devices }
                self.devicesCompleter.resume(returning: devices)
            }
        }
    }
}
