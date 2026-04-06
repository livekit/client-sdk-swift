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

@globalActor
public actor SoundPlayerActor {
    public static let shared = SoundPlayerActor()

    private init() {}
}

/// Options for controlling sound playback behavior.
public struct PlaybackOptions: Sendable {
    /// How to handle existing playback of the same sound.
    public enum Mode: Sendable {
        /// Play concurrently with any existing playback of the same sound.
        case concurrent
        /// Stop any existing playback of the same sound before playing.
        ///
        /// Replacement is scoped by sound identifier, not by destination.
        /// Existing local and remote playback for the same `id` are both stopped
        /// before the new playback starts.
        case replace
    }

    /// Where the sound should be played.
    public enum Destination: Sendable {
        /// Play locally only (through device speakers).
        case local
        /// Play for remote participants only (through WebRTC).
        ///
        /// Remote playback is best-effort. If the WebRTC mixer input path is unavailable
        /// (for example, no active remote-routing path is connected), playback is skipped.
        case remote
        /// Play both locally and for remote participants.
        ///
        /// Remote playback is best-effort and may be skipped when the WebRTC mixer input path
        /// is unavailable.
        case localAndRemote

        var includesLocal: Bool {
            self == .local || self == .localAndRemote
        }

        var includesRemote: Bool {
            self == .remote || self == .localAndRemote
        }
    }

    public var mode: Mode
    public var loop: Bool
    public var destination: Destination

    public init(mode: Mode = .concurrent, loop: Bool = false, destination: Destination = .localAndRemote) {
        self.mode = mode
        self.loop = loop
        self.destination = destination
    }
}
