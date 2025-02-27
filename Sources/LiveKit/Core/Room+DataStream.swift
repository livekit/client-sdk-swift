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

    /// Registers a handler for new byte streams matching the given topic.
    ///
    /// - Parameters:
    ///   - topic: Topic identifier; only streams with this topic will be handled.
    ///   - onNewStream: Handler closure passed the stream reader (``ByteStreamReader``) and the identity of the remote participant who opened the stream.
    ///
    func registerByteStreamHandler(for topic: String, onNewStream: @escaping ByteStreamHandler) async throws {
        try await incomingStreamManager.registerByteStreamHandler(for: topic, onNewStream)
    }

    /// Registers a handler for new text streams matching the given topic.
    ///
    /// - Parameters:
    ///   - topic: Topic identifier; only streams with this topic will be handled.
    ///   - onNewStream: Handler closure passed the stream reader (``TextStreamReader``) and the identity of the remote participant who opened the stream.
    ///
    func registerTextStreamHandler(for topic: String, onNewStream: @escaping TextStreamHandler) async throws {
        try await incomingStreamManager.registerTextStreamHandler(for: topic, onNewStream)
    }

    /// Unregisters a byte stream handler that was previously registered for the given topic.
    func unregisterByteStreamHandler(for topic: String) async {
        await incomingStreamManager.unregisterByteStreamHandler(for: topic)
    }

    /// Unregisters a text stream handler that was previously registered for the given topic.
    func unregisterTextStreamHandler(for topic: String) async {
        await incomingStreamManager.unregisterTextStreamHandler(for: topic)
    }
}

// MARK: - Objective-C Compatibility

extension Room {

    @objc
    @available(*, unavailable, message: "Use async registerByteStreamHandler(for:onNewStream:) method instead.")
    func registerByteStreamHandler(
        for topic: String,
        onNewStream: @escaping (ByteStreamReader, Participant.Identity) -> Void,
        onError: ((Error) -> Void)?
    ) {
        Task {
            do { try await registerByteStreamHandler(for: topic, onNewStream: onNewStream) }
            catch { onError?(error) }
        }
    }

    @objc
    @available(*, unavailable, message: "Use async registerTextStreamHandler(for:onNewStream:) method instead.")
    func registerTextStreamHandler(
        for topic: String,
        onNewStream: @escaping (TextStreamReader, Participant.Identity) -> Void,
        onError: ((Error) -> Void)?
    ) {
        Task {
            do { try await registerTextStreamHandler(for: topic, onNewStream: onNewStream) }
            catch { onError?(error) }
        }
    }

    @objc
    @available(*, unavailable, message: "Use async unregisterByteStreamHandler(for:) method instead.")
    func unregisterByteStreamHandler(
        for topic: String
    ) {
        Task { await unregisterByteStreamHandler(for: topic) }
    }

    @objc
    @available(*, unavailable, message: "Use async unregisterTextStreamHandler(for:) method instead.")
    func unregisterTextStreamHandler(
        for topic: String
    ) {
        Task { await unregisterTextStreamHandler(for: topic) }
    }
}
