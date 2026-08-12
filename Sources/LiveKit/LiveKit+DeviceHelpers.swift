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

// Upper bound on waiting for a permission prompt. Long enough for a user to decide, but ensures a
// prompt the system defers (for example when the app is not active) cannot suspend the caller.
private let kDeviceAccessRequestTimeout: TimeInterval = 30

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

    /// Requests authorization for the given media types, but only while the app can present the
    /// system permission dialog, and never blocks indefinitely.
    ///
    /// On iOS-family platforms this returns `false` without prompting when the app is not active
    /// (backgrounded or an app extension), so a caller woken in the background (for example by
    /// CallKit) does not wait on a dialog that cannot appear. On macOS the prompt can be presented
    /// regardless, so this behaves like ``ensureDeviceAccess(for:)``.
    ///
    /// The request is additionally bounded by a timeout: the system defers (rather than fails) a
    /// prompt it cannot present, so a bounded wait guarantees this always completes and resolves to
    /// `false` if the prompt never appears.
    static func ensureDeviceAccessIfForegrounded(for types: Set<AVMediaType>) async -> Bool {
        #if os(iOS) || os(visionOS) || os(tvOS)
        guard await AppStateListener.shared.isApplicationActive else { return false }
        #endif
        // requestAccess has no cancellation-aware continuation, so race it against a timeout via a
        // detached task rather than a task group (which would await the abandoned request).
        let completer = AsyncCompleter<Bool>(label: "DeviceAccess", defaultTimeout: kDeviceAccessRequestTimeout)
        Task.detached {
            let granted = await ensureDeviceAccess(for: types)
            completer.resume(returning: granted)
        }
        let granted = try? await completer.wait()
        return granted ?? false
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
    /// Ensures microphone access is granted before enabling recording.
    ///
    /// The WebRTC audio device no longer requests microphone permission implicitly, so the SDK
    /// requests it here while the app is foregrounded. When permission is undetermined and the app
    /// cannot present the prompt (backgrounded or app extension), this fails fast instead of blocking.
    ///
    /// - Throws: ``LiveKitError`` of type ``LiveKitErrorType/deviceAccessDenied`` when microphone
    ///   access is denied or restricted, or when permission is undetermined and cannot be requested.
    static func ensureMicrophoneAccessForRecording() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await ensureDeviceAccessIfForegrounded(for: [.audio]) else {
                // Distinguish "could not present the prompt" from "the user denied it".
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    throw LiveKitError(.deviceAccessDenied,
                                       message: "Microphone permission could not be requested. Request it while the app is in the foreground before enabling recording.")
                }
                throw LiveKitError(.deviceAccessDenied, message: "Microphone permission was denied.")
            }
        case .denied, .restricted:
            throw LiveKitError(.deviceAccessDenied, message: "Microphone permission is not granted.")
        @unknown default:
            throw LiveKitError(.deviceAccessDenied, message: "Microphone permission is not granted.")
        }
    }
}
