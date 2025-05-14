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
    /// Starts a pre-connect audio sequence that will automatically be cleaned up
    /// when the operation fails.
    ///
    /// - Parameters:
    ///   - timeout: The timeout for the remote participant to subscribe to the audio track.
    /// The room connection needs to be established and the remote participant needs to subscribe to the audio track
    /// before the timeout is reached. Otherwise, the audio stream will be flushed without sending.
    ///   - operation: The operation to perform while audio is being captured.
    ///   - onError: The error handler to call when an error occurs while sending the audio buffer.
    /// - Returns: The result of the operation.
    ///
    /// - Example:
    /// ```swift
    /// try await room.withPreConnectAudio {
    ///   // Audio is being captured automatically
    ///   // Perform any other (async) setup here
    ///   guard let connectionDetails = try await tokenService.fetchConnectionDetails(roomName: roomName, participantName: participantName) else {
    ///     return
    ///   }
    ///   try await room.connect(url: connectionDetails.serverUrl, token: connectionDetails.participantToken)
    /// } onError: { error in
    ///   print("Error sending audio buffer: \(error)")
    /// }
    /// ```
    ///
    /// - See: ``PreConnectAudioBuffer``
    /// - Important: Call ``AudioManager/setRecordingAlwaysPreparedMode(_:)`` during app launch sequence to request microphone permissions early.
    ///
    func withPreConnectAudio<T>(timeout: TimeInterval = PreConnectAudioBuffer.Constants.timeout,
                                _ operation: @Sendable @escaping () async throws -> T,
                                onError: PreConnectAudioBuffer.OnError? = nil) async throws -> T
    {
        preConnectBuffer.setErrorHandler(onError)
        try await preConnectBuffer.startRecording(timeout: timeout)

        do {
            return try await operation()
        } catch {
            preConnectBuffer.stopRecording(flush: true)
            throw error
        }
    }

    @available(*, deprecated, message: "Use withPreConnectAudio instead")
    func startCapturingBeforeConnecting(timeout: TimeInterval = PreConnectAudioBuffer.Constants.timeout) async throws {
        try await preConnectBuffer.startRecording(timeout: timeout)
    }
}
