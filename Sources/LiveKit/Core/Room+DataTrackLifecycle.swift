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

extension Room {
    func setupDataTracks() {
        _dataTracks.mutate { $0 = DataTracks(room: self) }
    }

    func cleanUpDataTracks(isFullReconnect: Bool = false) {
        // Session-scoped: keep the subsystem across a full reconnect so its managers can republish;
        // tear it down only on a real disconnect.
        guard !isFullReconnect else {
            dataTracks?.handleTransportsTeardown()
            // Remote data tracks outlive the reconnect — the subsystem re-attaches them to the
            // recreated participants. Detach them here, before `cleanUpParticipants` reports an
            // unpublish for tracks that were never unpublished.
            for participant in _state.remoteParticipants.values {
                participant.detachDataTracks()
            }
            return
        }
        _dataTracks.mutate { $0 = nil }
    }
}
