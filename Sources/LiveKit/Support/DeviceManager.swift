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

    public static let shared = DeviceManager()

    public static func prepare() {
        // Instantiate shared instance
        _ = shared
    }

    public var devices: [AVCaptureDevice] { _state.devices }

    struct State {
        var devices: [AVCaptureDevice] = []
        var didEnumerateDevices = false
    }

    private var _state = StateSync(State())

    public lazy var session: AVCaptureDevice.DiscoverySession = {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        #if os(iOS)
        deviceTypes = [
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
            .builtInWideAngleCamera,
            .builtInTelephotoCamera,
            .builtInUltraWideCamera,
        ]
        #else
        deviceTypes = [
            .builtInWideAngleCamera,
        ]
        #endif

        return AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes,
                                                mediaType: .video,
                                                position: .unspecified)
    }()

    var _observation: NSKeyValueObservation?

    init() {
        log()

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            _observation = session.observe(\.devices, options: [.initial, .new]) { [weak self] _, value in
                guard let self else { return }
                self.log("Devices: \(String(describing: value.newValue))")
                self._state.mutate {
                    $0.devices = value.newValue ?? []
                    $0.didEnumerateDevices = true
                }
            }
        }
    }
}
