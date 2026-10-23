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

// The async methods are `final`: an `@objc` method in a class extension is otherwise called
// through `objc_msgSend` and its completion-handler thunk, which runs it in a new task, so a Swift
// caller's cancellation never reaches it.
public extension LocalParticipant {
    // MARK: - Send

    /// Send a complete string to participants in the room.
    ///
    /// - Parameters:
    ///   - text: The string to send.
    ///   - topic: Topic identifier used to route the stream to appropriate handlers.
    /// - Returns: Information about the text stream used during the operation.
    /// - Throws: ``StreamError`` if the stream fails, or ``LiveKitError`` if the room is not
    ///   connected. `CancellationError` at once if the calling task is cancelled, but the call can
    ///   still complete.
    ///
    @discardableResult
    final func sendText(_ text: String, for topic: String) async throws -> TextStreamInfo {
        try await sendText(text, options: StreamTextOptions(topic: topic))
    }

    /// Send a complete string to participants in the room with custom options.
    ///
    /// - SeeAlso: ``sendText(_:for:)``
    ///
    @discardableResult
    final func sendText(_ text: String, options: StreamTextOptions) async throws -> TextStreamInfo {
        let room = try requireRoom()
        return try await room.dataStreams.sendText(text, options: options)
    }

    /// Send a complete string with files attached to participants in the room.
    ///
    /// The text goes first. Then each file goes out as its own byte stream, all at the same time, on
    /// the text's topic, to its recipients, and with its compression and sender. The text stream
    /// lists the files' stream IDs in ``TextStreamInfo/attachedStreamIDs``, after any IDs `options`
    /// already lists, and each file's ``ByteStreamInfo/id`` is one of them.
    ///
    /// ```swift
    /// try await room.localParticipant.sendText("Here is the report", options: StreamTextOptions(topic: "chat"), attachments: [reportURL])
    /// ```
    ///
    /// - Parameters:
    ///   - text: The string to send.
    ///   - options: Options for the text stream.
    ///   - attachments: The URLs of the files on disk to send with the text.
    /// - Returns: Information about the text stream.
    /// - Throws: ``StreamError`` if a stream fails, or ``LiveKitError`` if the room is not
    ///   connected. The first file that fails ends the call at once and cancels the other files'
    ///   sends; the text has already gone out. `CancellationError` at once if the calling task is
    ///   cancelled, but the sends can still complete.
    ///
    @discardableResult
    final func sendText(_ text: String, options: StreamTextOptions, attachments: [URL]) async throws -> TextStreamInfo {
        let room = try requireRoom()
        return try await room.dataStreams.sendText(text, options: options, attachments: attachments)
    }

    /// Send complete data to participants in the room.
    ///
    /// - Parameters:
    ///   - data: The data to send.
    ///   - topic: Topic identifier used to route the stream to appropriate handlers.
    /// - Returns: Information about the byte stream used during the operation.
    /// - Throws: ``StreamError`` if the stream fails, or ``LiveKitError`` if the room is not
    ///   connected. `CancellationError` at once if the calling task is cancelled, but the call can
    ///   still complete.
    ///
    /// For data that is not in memory yet, use ``streamBytes(for:)``. For a file on disk, use
    /// ``sendFile(_:for:)``.
    ///
    @discardableResult
    final func sendBytes(_ data: Data, for topic: String) async throws -> ByteStreamInfo {
        try await sendBytes(data, options: StreamByteOptions(topic: topic))
    }

    /// Send complete data to participants in the room with custom options.
    ///
    /// - SeeAlso: ``sendBytes(_:for:)``
    ///
    @discardableResult
    final func sendBytes(_ data: Data, options: StreamByteOptions) async throws -> ByteStreamInfo {
        let room = try requireRoom()
        return try await room.dataStreams.sendBytes(data, options: options)
    }

    /// Send a file on disk to participants in the room.
    ///
    /// - Parameters:
    ///   - fileURL: The URL of the file on disk to send.
    ///   - topic: Topic identifier used to route the stream to appropriate handlers.
    /// - Returns: Information about the byte stream used during the operation.
    /// - Throws: ``StreamError`` if the stream fails, or ``LiveKitError`` if the room is not
    ///   connected. `CancellationError` at once if the calling task is cancelled, but the call can
    ///   still complete.
    ///
    @discardableResult
    final func sendFile(_ fileURL: URL, for topic: String) async throws -> ByteStreamInfo {
        try await sendFile(fileURL, options: StreamByteOptions(topic: topic))
    }

    /// Send a file on disk to participants in the room with custom options.
    ///
    /// - SeeAlso: ``sendFile(_:for:)``
    ///
    @discardableResult
    final func sendFile(_ fileURL: URL, options: StreamByteOptions) async throws -> ByteStreamInfo {
        let room = try requireRoom()
        return try await room.dataStreams.sendFile(fileURL, options: options)
    }

    // MARK: - Stream

    /// Stream text incrementally to participants in the room.
    ///
    /// - Parameters:
    ///   - topic: Topic identifier used to route the stream to appropriate handlers.
    /// - Returns: A ``TextStreamWriter`` for sending text.
    /// - Throws: ``StreamError`` if the stream fails, or ``LiveKitError`` if the room is not
    ///   connected. `CancellationError` at once if the calling task is cancelled, but the call can
    ///   still complete.
    ///
    @discardableResult
    final func streamText(for topic: String) async throws -> TextStreamWriter {
        try await streamText(options: StreamTextOptions(topic: topic))
    }

    /// Stream text incrementally to participants in the room with custom options.
    ///
    /// - SeeAlso: ``streamText(for:)``
    ///
    @discardableResult
    final func streamText(options: StreamTextOptions) async throws -> TextStreamWriter {
        let room = try requireRoom()
        return try await room.dataStreams.streamText(options: options)
    }

    /// Stream bytes incrementally to participants in the room.
    ///
    /// - Parameters:
    ///   - topic: Topic identifier used to route the stream to appropriate handlers.
    /// - Returns: A ``ByteStreamWriter`` for sending data.
    /// - Throws: ``StreamError`` if the stream fails, or ``LiveKitError`` if the room is not
    ///   connected. `CancellationError` at once if the calling task is cancelled, but the call can
    ///   still complete.
    ///
    /// For sending files, use ``sendFile(_:for:)`` instead.
    ///
    @discardableResult
    final func streamBytes(for topic: String) async throws -> ByteStreamWriter {
        try await streamBytes(options: StreamByteOptions(topic: topic))
    }

    /// Stream bytes incrementally to participants in the room with custom options.
    ///
    /// - SeeAlso: ``streamBytes(for:)``
    ///
    final func streamBytes(options: StreamByteOptions) async throws -> ByteStreamWriter {
        let room = try requireRoom()
        return try await room.dataStreams.streamBytes(options: options)
    }
}
