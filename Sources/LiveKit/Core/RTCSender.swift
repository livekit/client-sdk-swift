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

/// A `@RTC`-confined handle on an `LKRTCRtpSender`.
///
/// The raw sender is a libwebrtc proxy: every member call is a signaling-thread `BlockingCall`,
/// and its last release runs a blocking destructor. `LKRTCRtpSender` is intentionally **not**
/// `Sendable`, so it cannot leave this type; the raw pointer is reachable only through ``raw``,
/// which is `@RTC`-isolated — a call on it therefore cannot be written off the RTC executor.
struct RTCSender: Sendable {
    /// `senderId` maps to libwebrtc's `id()`, which is thread-safe (a `BYPASS` proxy member).
    /// Captured once at construction so reading it later needs no actor hop.
    let senderId: String

    private let box: RTCBox<LKRTCRtpSender>

    @RTC
    init(_ raw: LKRTCRtpSender) {
        senderId = raw.senderId
        box = RTCBox(raw)
    }

    /// The underlying sender. `@RTC`-isolated by design — every use is on the RTC executor.
    @RTC var raw: LKRTCRtpSender { box.value }
}
