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

import Foundation

internal import LiveKitWebRTC

/// A `@RTC`-confined handle on an `LKRTCMediaStreamTrack`.
///
/// The raw track is a libwebrtc proxy: `set_enabled`, the renderer sink attach and detach, `volume`
/// and the audio-processing options are all `BlockingCall`s onto WebRTC's signaling or worker
/// thread, and its last release runs a blocking destructor. `LKRTCMediaStreamTrack` is
/// intentionally **not** `Sendable`, so it cannot leave this type; the raw pointer is reachable
/// only through ``raw``, which is `@RTC`-isolated, or ``blocking(_:)``, which is the opt-in hop for
/// the public synchronous APIs that block their caller by contract.
struct RTCMediaTrack: Sendable {
    /// `trackId` and `kind` map to libwebrtc's `id()`/`kind()`, which are thread-safe (`BYPASS`
    /// proxy members). Captured once at construction so reading them later needs no actor hop.
    let trackId: String
    let kind: String

    private let box: RTCBox<LKRTCMediaStreamTrack>

    /// Nonisolated: remote tracks arrive in peer-connection delegate callbacks on the signaling
    /// thread, and boxing a reference blocks nothing.
    init(_ raw: LKRTCMediaStreamTrack) {
        trackId = raw.trackId
        kind = raw.kind
        box = RTCBox(raw)
    }

    /// The underlying track. `@RTC`-isolated by design — every use is on the RTC executor.
    @RTC var raw: LKRTCMediaStreamTrack { box.value }

    /// Runs `body` with the raw track on the RTC executor, blocking the caller until it returns.
    /// For the public synchronous APIs that document that they block; async code uses ``raw``.
    func blocking<T>(_ body: (LKRTCMediaStreamTrack) throws -> T) rethrows -> T {
        try box.blocking(body)
    }

    /// Runs `teardown` with the raw track off both the cooperative pool and the RTC executor, for
    /// `deinit` paths whose detach blocks on a WebRTC thread.
    func park(_ teardown: @escaping @Sendable (LKRTCMediaStreamTrack) -> Void) {
        box.park(teardown)
    }
}
