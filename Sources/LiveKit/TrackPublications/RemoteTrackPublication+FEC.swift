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

public extension RemoteTrackPublication {
    /// Sets the proactive FlexFEC protection the server adds to this video track.
    ///
    /// Repairs let the receiver recover lost packets without waiting for a retransmission, at the
    /// cost of extra bandwidth. The protection changes without renegotiation, and also applies while
    /// adaptive stream manages the track.
    ///
    /// - Note: Repairs are only sent when the server has downstream FlexFEC enabled and FlexFEC was
    ///   negotiated, which requires ``LiveKitSDK/setFlexFECEnabled(_:)``. Otherwise the request has
    ///   no effect.
    func set(fecProtection newValue: FECProtection) async throws {
        guard kind == .video else {
            throw LiveKitError(.invalidState, message: "FEC protection is only supported for video tracks")
        }
        // No-op if already the desired value
        let trackSettings = _state.trackSettings
        guard trackSettings.fecProtection != newValue else { return }

        guard isSubscribed else {
            throw LiveKitError(.invalidState, message: "Track must be subscribed")
        }

        let settings = trackSettings.copyWith(fecProtection: .value(newValue))
        // Attempt to set the new settings
        try await send(trackSettings: settings)
    }

    /// The FlexFEC protection requested with ``set(fecProtection:)``.
    var fecProtection: FECProtection { _state.trackSettings.fecProtection ?? .disabled }
}
