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

import AVFoundation

#if canImport(UIKit) && (os(iOS) || os(visionOS) || os(tvOS))
import UIKit
#endif

public extension LiveKitSDK {
    /// Helper method to ensure authorization for video(camera) / audio(microphone) permissions in a single call.
    static func ensureDeviceAccess(for types: Set<AVMediaType>) async -> Bool {
        for type in types {
            if ![.video, .audio].contains(type) {
                log("types must be .video or .audio", .error)
            }

            let status = AVCaptureDevice.authorizationStatus(for: type)
            switch status {
            case .notDetermined:
                if await !(AVCaptureDevice.requestAccess(for: type)) {
                    return false
                }
            case .restricted, .denied: return false
            case .authorized: continue // No action needed for authorized status.
            @unknown default:
                log("Unknown AVAuthorizationStatus", .error)
                return false
            }
        }

        return true
    }

    /// Requests authorization for the given media types, but only while the app is foregrounded so
    /// the system permission dialog can actually appear. A no-op returning `false` on non-active or
    /// non-UIKit (extension/background) contexts. Suitable for paths that must never block, where
    /// prompting only makes sense when the app can present UI.
    static func ensureDeviceAccessIfForegrounded(for types: Set<AVMediaType>) async -> Bool {
        #if canImport(UIKit) && (os(iOS) || os(visionOS) || os(tvOS))
        guard await UIApplication.shared.applicationState == .active else { return false }
        return await ensureDeviceAccess(for: types)
        #else
        return false
        #endif
    }

    /// Blocking version of ensureDeviceAccess that uses DispatchGroup to wait for permissions.
    static func ensureDeviceAccessSync(for types: Set<AVMediaType>) -> Bool {
        let group = DispatchGroup()
        nonisolated(unsafe) var result = false

        for type in types {
            if ![.video, .audio].contains(type) {
                log("types must be .video or .audio", .error)
            }

            let status = AVCaptureDevice.authorizationStatus(for: type)
            switch status {
            case .notDetermined:
                group.enter()
                AVCaptureDevice.requestAccess(for: type) { granted in
                    if !granted {
                        result = false
                    }
                    group.leave()
                }
            case .restricted, .denied:
                return false
            case .authorized:
                continue // No action needed for authorized status
            @unknown default:
                log("Unknown AVAuthorizationStatus", .error)
                return false
            }
        }

        // Wait for all permission requests to complete
        group.wait()

        return result
    }
}
