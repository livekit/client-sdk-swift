/*
 * Copyright 2025 LiveKit
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

public extension Room {
    /// Start capturing audio before connecting to the server,
    /// so that it's not lost when the connection is established.
    /// It will be automatically sent via data stream to the other participant
    /// using the `PreConnectAudioBuffer.dataTopic` when the local track is subscribed.
    /// - See: ``PreConnectAudioBuffer``
    /// - Note: Use ``AudioManager/setRecordingAlwaysPreparedMode(_:)`` to request microphone permissions early.
    func startCapturingBeforeConnecting() async throws {
        try await preConnectBuffer.startRecording()
    }
}
