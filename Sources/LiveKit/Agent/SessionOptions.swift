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

/// Options for creating a ``Session``.
public struct SessionOptions: Sendable {
    /// The undelying ``Room`` object for the session.
    public var room: Room
    /// Whether to enable audio pre-connect with ``PreConnectAudioBuffer``.
    /// If enabled, the microphone will be enabled before connecting to the room.
    /// Use ``LocalMedia`` or ``AudioManager/setRecordingAlwaysPreparedMode(_:)``
    /// to request microphone permissions early in the app lifecycle.
    public var preConnectAudio: Bool
    /// The timeout for the agent to connect, in seconds.
    /// If exceeded, the ``Agent`` will transition to a failed state.
    public var agentConnectTimeout: TimeInterval

    public init(
        room: Room = .init(),
        preConnectAudio: Bool = true,
        agentConnectTimeout: TimeInterval = 20
    ) {
        self.room = room
        self.preConnectAudio = preConnectAudio
        self.agentConnectTimeout = agentConnectTimeout
    }
}
