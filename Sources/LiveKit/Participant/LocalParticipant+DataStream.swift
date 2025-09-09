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

public extension LocalParticipant {
    // MARK: - Send

    /// Send a complete string to participants in the room.
    ///
    /// - Parameters:
    ///   - text: The string to send.
    ///   - topic: Topic identifier used to route the stream to appropriate handlers.
    /// - Returns: Information about the text stream used during the operation.
    /// - Throws: Throws ``StreamError`` if the operation fails.
    ///
    @discardableResult
    func sendText(_ text: String, for topic: String) async throws -> TextStreamInfo {
        try await sendText(text, options: StreamTextOptions(topic: topic))
    }

    /// Send a complete string to participants in the room with custom options.
    ///
    /// - SeeAlso: ``sendText(_:for:)``
    ///
    @discardableResult
    func sendText(_ text: String, options: StreamTextOptions) async throws -> TextStreamInfo {
        let room = try requireRoom()
        return try await room.outgoingStreamManager.sendText(text, options: options)
    }

    /// Send a file on disk to participants in the room.
    ///
    /// - Parameters:
    ///   - fileURL: The URL of the file on disk to send.
    ///   - topic: Topic identifier used to route the stream to appropriate handlers.
    /// - Returns: Information about the byte stream used during the operation.
    /// - Throws: Throws ``StreamError`` if the operation fails.
    ///
    @discardableResult
    func sendFile(_ fileURL: URL, for topic: String) async throws -> ByteStreamInfo {
        try await sendFile(fileURL, options: StreamByteOptions(topic: topic))
    }

    /// Send a file on disk to participants in the room with custom options.
    ///
    /// - SeeAlso: ``sendFile(_:for:)``
    ///
    @discardableResult
    func sendFile(_ fileURL: URL, options: StreamByteOptions) async throws -> ByteStreamInfo {
        let room = try requireRoom()
        return try await room.outgoingStreamManager.sendFile(fileURL, options: options)
    }

    // MARK: - Stream

    /// Stream text incrementally to participants in the room.
    ///
    /// - Parameters:
    ///   - topic: Topic identifier used to route the stream to appropriate handlers.
    /// - Returns: A ``TextStreamWriter`` for sending text.
    /// - Throws: Throws ``StreamError`` if the operation fails.
    ///
    @discardableResult
    func streamText(for topic: String) async throws -> TextStreamWriter {
        try await streamText(options: StreamTextOptions(topic: topic))
    }

    /// Stream text incrementally to participants in the room with custom options.
    ///
    /// - SeeAlso: ``streamText(for:)``
    ///
    @discardableResult
    func streamText(options: StreamTextOptions) async throws -> TextStreamWriter {
        let room = try requireRoom()
        return try await room.outgoingStreamManager.streamText(options: options)
    }

    /// Stream bytes incrementally to participants in the room.
    ///
    /// - Parameters:
    ///   - topic: Topic identifier used to route the stream to appropriate handlers.
    /// - Returns: A ``ByteStreamWriter`` for sending data.
    /// - Throws: Throws ``StreamError`` if the operation fails.
    ///
    /// For sending files, use ``sendFile(_:for:)`` instead.
    ///
    @discardableResult
    func streamBytes(for topic: String) async throws -> ByteStreamWriter {
        try await streamBytes(options: StreamByteOptions(topic: topic))
    }

    /// Stream bytes incrementally to participants in the room with custom options.
    ///
    /// - SeeAlso: ``streamBytes(for:)``
    ///
    func streamBytes(options: StreamByteOptions) async throws -> ByteStreamWriter {
        let room = try requireRoom()
        return try await room.outgoingStreamManager.streamBytes(options: options)
    }
}

// MARK: - Objective-C Compatibility

public extension LocalParticipant {
    @objc
    @available(*, unavailable, message: "Use async sendText(_:options:) method instead.")
    func sendText(
        text: String,
        options: StreamTextOptions,
        onCompletion: @Sendable @escaping (TextStreamInfo) -> Void,
        onError: (@Sendable (Error) -> Void)?
    ) {
        Task {
            do { try await onCompletion(sendText(text, options: options)) }
            catch { onError?(error) }
        }
    }

    @objc
    @available(*, unavailable, message: "Use async sendFile(_:options:) method instead.")
    func sendFile(
        fileURL: URL,
        options: StreamByteOptions,
        onCompletion: @Sendable @escaping (ByteStreamInfo) -> Void,
        onError: (@Sendable (Error) -> Void)?
    ) {
        Task {
            do { try await onCompletion(sendFile(fileURL, options: options)) }
            catch { onError?(error) }
        }
    }

    @objc
    @available(*, unavailable, message: "Use async streamText(options:) method instead.")
    func streamText(
        options: StreamTextOptions,
        streamHandler: @Sendable @escaping (TextStreamWriter) -> Void,
        onError: (@Sendable (Error) -> Void)?
    ) {
        Task {
            do { try await streamHandler(streamText(options: options)) }
            catch { onError?(error) }
        }
    }

    @objc
    @available(*, unavailable, message: "Use async streamBytes(options:) method instead.")
    func streamBytes(
        options: StreamByteOptions,
        streamHandler: @Sendable @escaping (ByteStreamWriter) -> Void,
        onError: (@Sendable (Error) -> Void)?
    ) {
        Task {
            do { try await streamHandler(streamBytes(options: options)) }
            catch { onError?(error) }
        }
    }
}
