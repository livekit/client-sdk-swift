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
        try Self.checkReserved(topic: topic)
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
        try Self.checkReserved(topic: topic)
        try await incomingStreamManager.registerTextStreamHandler(for: topic, onNewStream)
    }

    /// Unregisters a byte stream handler that was previously registered for the given topic.
    ///
    /// Throws if `topic` uses the reserved `lk.` prefix - the SDK uses this namespace for
    /// internal functionality.
    @objc
    func unregisterByteStreamHandler(for topic: String) async throws {
        try Self.checkReserved(topic: topic)
        await incomingStreamManager.unregisterByteStreamHandler(for: topic)
    }

    /// Unregisters a text stream handler that was previously registered for the given topic.
    ///
    /// Throws if `topic` uses the reserved `lk.` prefix - the SDK uses this namespace for
    /// internal functionality.
    @objc
    func unregisterTextStreamHandler(for topic: String) async throws {
        try Self.checkReserved(topic: topic)
        await incomingStreamManager.unregisterTextStreamHandler(for: topic)
    }
}

extension Room {
    /// `lk.` is LiveKit's reserved namespace per the server convention. User code may not
    /// register or unregister stream handlers on any topic with this prefix; SDK-internal
    /// call sites bypass this check by going through `incomingStreamManager` directly.
    static func checkReserved(topic: String) throws {
        guard !topic.hasPrefix("lk.") else {
            throw LiveKitError(.invalidParameter,
                               message: "Stream topic prefix 'lk.' is reserved for internal SDK use")
        }
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
            do { try await registerByteStreamHandler(for: topic, onNewStream: onNewStream) } catch { onError?(error) }
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
            do { try await registerTextStreamHandler(for: topic, onNewStream: onNewStream) } catch { onError?(error) }
        }
    }
}
