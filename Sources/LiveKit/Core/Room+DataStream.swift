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
    /// Registers a handler for incoming byte streams matching the given topic.
    ///
    /// - Parameters:
    ///   - topic: Topic identifier that filters which streams will be handled.
    ///     Only streams with a matching topic will trigger the handler.
    ///   - onNewStream: Handler that is invoked whenever a remote participant
    ///     opens a new stream with the matching topic. The handler receives a
    ///     ``ByteStreamReader`` for consuming the stream data and the identity of
    ///     the remote participant who initiated the stream.
    ///
    func registerByteStreamHandler(for topic: String, onNewStream: @escaping ByteStreamHandler) async throws {
        try await incomingStreamManager.registerByteStreamHandler(for: topic, onNewStream)
    }

    /// Registers a handler for incoming text streams matching the given topic.
    ///
    /// - Parameters:
    ///   - topic: Topic identifier that filters which streams will be handled.
    ///     Only streams with a matching topic will trigger the handler.
    ///   - onNewStream: Handler that is invoked whenever a remote participant
    ///     opens a new stream with the matching topic. The handler receives a
    ///     ``TextStreamReader`` for consuming the stream data and the identity of
    ///     the remote participant who initiated the stream.
    ///
    func registerTextStreamHandler(for topic: String, onNewStream: @escaping TextStreamHandler) async throws {
        try await incomingStreamManager.registerTextStreamHandler(for: topic, onNewStream)
    }

    /// Unregisters a byte stream handler that was previously registered for the given topic.
    @objc
    func unregisterByteStreamHandler(for topic: String) async {
        await incomingStreamManager.unregisterByteStreamHandler(for: topic)
    }

    /// Unregisters a text stream handler that was previously registered for the given topic.
    @objc
    func unregisterTextStreamHandler(for topic: String) async {
        await incomingStreamManager.unregisterTextStreamHandler(for: topic)
    }
}

// MARK: - Objective-C Compatibility

public extension Room {
    @objc
    @available(*, deprecated, message: "Use async registerByteStreamHandler(for:onNewStream:) method instead.")
    func registerByteStreamHandler(
        for topic: String,
        onNewStream: @Sendable @escaping (ByteStreamReader, Participant.Identity) -> Void,
        onError: (@Sendable (Error) -> Void)?
    ) {
        Task {
            do { try await registerByteStreamHandler(for: topic, onNewStream: onNewStream) }
            catch { onError?(error) }
        }
    }

    @objc
    @available(*, deprecated, message: "Use async registerTextStreamHandler(for:onNewStream:) method instead.")
    func registerTextStreamHandler(
        for topic: String,
        onNewStream: @Sendable @escaping (TextStreamReader, Participant.Identity) -> Void,
        onError: (@Sendable (Error) -> Void)?
    ) {
        Task {
            do { try await registerTextStreamHandler(for: topic, onNewStream: onNewStream) }
            catch { onError?(error) }
        }
    }
}
