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
    /// - Note: Repairs are only sent when the server has downstream FlexFEC enabled, otherwise the
    ///   request has no effect. Receiving them does not require ``LiveKitSDK/setFlexFECEnabled(_:)``.
    func set(fecProtection newValue: FECProtection) async throws {
        guard kind == .video else {
            throw LiveKitError(.invalidState, message: "FEC protection is only supported for video tracks")
        }
        // No-op if already the desired value
        guard fecProtection != newValue else { return }

        guard isSubscribed else {
            throw LiveKitError(.invalidState, message: "Track must be subscribed")
        }

        // Attempt to set the new settings
        try await send(trackSettings: _state.trackSettings, fecProtection: .value(newValue))
    }

    /// The FlexFEC protection requested with ``set(fecProtection:)``.
    var fecProtection: FECProtection { _state.fecProtection ?? .disabled }
}

extension RemoteTrackPublication {
    /// Whether a newly attached track needs its settings sent again: settings the user chose
    /// without adaptive stream, or FEC protection other than disabled.
    var shouldReplayTrackSettings: Bool {
        let state = _state.copy()
        return state.hasManualTrackSettings || state.fecProtection.map { $0 != .disabled } == true
    }

    /// Sends the current track settings and FEC protection again for a newly attached track.
    ///
    /// A resubscription can create a new server subscription, which starts from defaults.
    /// Sending the same values to a subscription that kept them changes nothing.
    func replayTrackSettings() async {
        do {
            try await send(trackSettings: _state.trackSettings)
        } catch {
            log("Failed to replay track settings, sid: \(sid), error: \(error)", .warning)
        }
    }
}
