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

/// Confines a raw libwebrtc proxy object to the ``RTC`` executor.
///
/// libwebrtc proxies block on WebRTC's threads for every call and for the release of the last
/// reference. This box exposes the raw object only through ``value``, which is `@RTC`-isolated, so
/// no call on it can be written off the RTC executor, and releases it on the concurrent ``RTC/releaseQueue`` from
/// `deinit`. It is generic so one type serves every proxy facade (``RTCSender`` and peers).
///
/// `@unchecked Sendable` is confined to this one type and justified by the isolated accessor: a
/// facade keeps its box `private` and forwards `@RTC var raw { box.value }`, so the raw pointer is
/// never reachable from a nonisolated context. (A truly `@RTC`-isolated class cannot release a
/// non-`Sendable` raw from its nonisolated `deinit` below iOS 18.4's `isolated deinit`.)
final class RTCBox<Raw: AnyObject>: @unchecked Sendable {
    private let raw: Raw

    init(_ raw: Raw) { self.raw = raw }

    @RTC var value: Raw { raw }

    deinit {
        RTC.park(raw)
    }
}
