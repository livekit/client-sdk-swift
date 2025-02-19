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

extension Room {

    /// Registers a handler for new byte streams matching the given topic.
    ///
    /// - Parameters:
    ///   - topic: Topic identifier; only streams with this topic will be handled.
    ///   - handler: Handler closure passed the stream reader (``ByteStreamReader``) and the identity of the remote participant who opened the stream.
    ///
    public func registerByteStreamHandler(for topic: String, _ handler: @escaping ByteStreamHandler) async throws {
        try await incomingStreamManager.registerByteStreamHandler(for: topic, handler)
    }

    /// Registers a handler for new text streams matching the given topic.
    ///
    /// - Parameters:
    ///   - topic: Topic identifier; only streams with this topic will be handled.
    ///   - handler: Handler closure passed the stream reader (``TextStreamReader``) and the identity of the remote participant who opened the stream.
    ///
    public func registerTextStreamHandler(for topic: String, _ handler: @escaping TextStreamHandler) async throws {
        try await incomingStreamManager.registerTextStreamHandler(for: topic, handler)
    }

    /// Unregisters a byte stream handler that was previously registered for the given topic.
    public func unregisterByteStreamHandler(for topic: String) async {
        await incomingStreamManager.unregisterByteStreamHandler(for: topic)
    }

    /// Unregisters a text stream handler that was previously registered for the given topic.
    func unregisterTextStreamHandler(for topic: String) async {
        await incomingStreamManager.unregisterTextStreamHandler(for: topic)
    }
}
