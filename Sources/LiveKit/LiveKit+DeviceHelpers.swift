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

    /// Blocking version of ``ensureDeviceAccess(for:)`` that uses a `DispatchGroup` to wait for permissions.
    ///
    /// - Warning: Requesting `.notDetermined` permission blocks the calling thread until the user responds.
    ///   When the app is backgrounded (for example, woken by a CallKit call) the system dialog never appears
    ///   and the call blocks indefinitely. Prefer the async ``ensureDeviceAccess(for:)`` instead.
    @available(*, deprecated, message: "Blocking permission requests can hang the calling thread. Use the async ensureDeviceAccess(for:) instead.")
    static func ensureDeviceAccessSync(for types: Set<AVMediaType>) -> Bool {
        let group = DispatchGroup()
        nonisolated(unsafe) var granted = true

        for type in types {
            if ![.video, .audio].contains(type) {
                log("types must be .video or .audio", .error)
            }

            let status = AVCaptureDevice.authorizationStatus(for: type)
            switch status {
            case .notDetermined:
                group.enter()
                AVCaptureDevice.requestAccess(for: type) { result in
                    if !result {
                        granted = false
                    }
                    group.leave()
                }
            case .restricted, .denied:
                return false
            case .authorized:
                continue // No action needed for authorized status.
            @unknown default:
                log("Unknown AVAuthorizationStatus", .error)
                return false
            }
        }

        // Wait for all permission requests to complete.
        group.wait()

        return granted
    }
}

extension LiveKitSDK {
    /// How to handle the current microphone authorization status before starting capture.
    enum MicrophoneAccessAction: Equatable {
        /// Already authorized, start capture.
        case proceed
        /// Not yet determined. Trigger the system prompt for a later attempt and fail this one.
        case triggerPromptAndDeny
        /// Denied or restricted, so no prompt can change the outcome.
        case deny
    }

    /// Decides how to handle the given microphone authorization status.
    ///
    /// Separated from the request itself so the policy can be tested without real authorization state.
    static func microphoneAccessAction(for status: AVAuthorizationStatus) -> MicrophoneAccessAction {
        switch status {
        case .authorized:
            return .proceed
        case .notDetermined:
            return .triggerPromptAndDeny
        case .denied, .restricted:
            return .deny
        @unknown default:
            log("Unknown AVAuthorizationStatus", .error)
            return .deny
        }
    }

    /// Ensures microphone authorization before the `AudioDeviceModule` opens the input.
    ///
    /// WebRTC's `AudioEngineDevice` stopped requesting microphone permission itself in
    /// `144.7559.12`, so the SDK triggers the request here.
    ///
    /// The request is deliberately not awaited. `AVCaptureDevice.requestAccess` does not call
    /// back until the user answers, and when no dialog can be presented, for example because
    /// the app was woken in the background by CallKit, that answer never arrives. Waiting for
    /// it would reintroduce the hang the upstream change removed, so capture fails fast and the
    /// next attempt succeeds once permission has been granted.
    ///
    /// Apps that want the prompt resolved before the first publish should call
    /// ``ensureDeviceAccess(for:)`` while foregrounded.
    ///
    /// - Throws: ``LiveKitError`` with type `.deviceAccessDenied`, matching what the
    ///   `AudioDeviceModule` reports when it refuses to enable the input.
    static func ensureMicrophoneAccessOrThrow() throws {
        switch microphoneAccessAction(for: AVCaptureDevice.authorizationStatus(for: .audio)) {
        case .proceed:
            return
        case .triggerPromptAndDeny:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                log("Microphone permission request completed, granted: \(granted)")
            }
            throw microphoneAccessDeniedError()
        case .deny:
            throw microphoneAccessDeniedError()
        }
    }

    private static func microphoneAccessDeniedError() -> LiveKitError {
        LiveKitError(.deviceAccessDenied, message: "Microphone permission is not granted")
    }
}
