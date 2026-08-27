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

// Whether this process is an app extension, which cannot present a permission dialog. The broadcast
// upload extension the SDK supports (see `LKSampleHandler`) is headless, so no prompt can appear.
// The `.appex` bundle suffix is Apple's documented way to detect an extension process.
private let kIsAppExtension = Bundle.main.bundleURL.pathExtension == "appex"

#if canImport(UIKit) && (os(iOS) || os(visionOS) || os(tvOS))
// Resolves `UIApplication.shared` through the Objective-C runtime because referencing it directly
// does not compile with APPLICATION_EXTENSION_API_ONLY=YES, and consumers build this module into
// broadcast upload extensions. An extension process is prohibited from calling `sharedApplication`,
// so callers must be guarded by `kIsAppExtension`. The selector itself would resolve there too.
@MainActor
private func isApplicationForegrounded() -> Bool {
    let selector = NSSelectorFromString("sharedApplication")
    guard UIApplication.responds(to: selector),
          let shared = UIApplication.perform(selector),
          let application = shared.takeUnretainedValue() as? UIApplication
    else { return false }
    // Only .active can actually present the alert. While .inactive (locked screen, call banner, app
    // switcher, or launch before the scene activates) the system defers it, and requestAccess has no
    // cancellation-aware continuation, so waiting there would suspend the caller for as long as the
    // app stays inactive. Failing fast instead lets the next attempt prompt normally.
    return application.applicationState == .active
}
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
    /// Requests authorization for the given media types, but only while the app can present the
    /// system permission dialog.
    ///
    /// An app extension always returns `false` without prompting, since it cannot present the dialog.
    ///
    /// On iOS-family platforms this also returns `false` without prompting unless the app is active, so
    /// a caller woken in the background (for example by CallKit) does not wait on an alert that cannot
    /// appear. An inactive app is treated the same way, since the system defers the alert there and
    /// waiting would suspend the caller. On macOS the prompt can be presented regardless, so this
    /// otherwise behaves like ``ensureDeviceAccess(for:)``.
    static func ensureDeviceAccessIfForegrounded(for types: Set<AVMediaType>) async -> Bool {
        if kIsAppExtension { return false }
        #if canImport(UIKit) && (os(iOS) || os(visionOS) || os(tvOS))
        guard await isApplicationForegrounded() else { return false }
        #endif
        return await ensureDeviceAccess(for: types)
    }

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
                    if kIsAppExtension {
                        throw LiveKitError(.deviceAccessDenied,
                                           message: "Microphone permission cannot be requested from an app extension. Request it in the host app before enabling recording.")
                    }
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
