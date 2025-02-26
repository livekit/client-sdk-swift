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

    @discardableResult
    func sendText(_ text: String, for topic: String) async throws -> TextStreamInfo {
        try await sendText(text, options: StreamTextOptions(topic: topic))
    }

    @discardableResult
    func sendText(_ text: String, options: StreamTextOptions) async throws -> TextStreamInfo {
        let room = try requireRoom()
        let writer = try await room.outgoingStreamManager.streamText(options: options)

        try await writer.write(text)
        try await writer.close()

        return writer.info
    }
    
    @discardableResult
    func sendFile(_ fileURL: URL, for topic: String) async throws -> ByteStreamInfo {
        try await sendFile(fileURL, options: StreamByteOptions(topic: topic))
    }
    
    @discardableResult
    func sendFile(_ fileURL: URL, options: StreamByteOptions) async throws -> ByteStreamInfo {
        let room = try requireRoom()
        
        guard let fileInfo = try FileInfo(for: fileURL) else {
            throw StreamError.fileInfoUnavailable
        }
        let options = StreamByteOptions(
            topic: options.topic,
            attributes: options.attributes,
            destinationIdentities: options.destinationIdentities,
            id: options.id,
            mimeType: options.mimeType ?? fileInfo.mimeType,
            name: options.name ?? fileInfo.name,
            totalSize: fileInfo.size // Cannot be overwritten by user
        )
        let writer = try await room.outgoingStreamManager.streamBytes(options: options)
        try await writer.write(contentsOf: fileURL)
        try await writer.close()
        
        return writer.info
    }

    // MARK: - Stream

    func streamText(for topic: String) async throws -> TextStreamWriter {
        try await streamText(options: StreamTextOptions(topic: topic))
    }

    func streamText(options: StreamTextOptions) async throws -> TextStreamWriter {
        let room = try requireRoom()
        return try await room.outgoingStreamManager.streamText(options: options)
    }

    func streamBytes(for topic: String) async throws -> ByteStreamWriter {
        try await streamBytes(options: StreamByteOptions(topic: topic))
    }

    func streamBytes(options: StreamByteOptions) async throws -> ByteStreamWriter {
        let room = try requireRoom()
        return try await room.outgoingStreamManager.streamBytes(options: options)
    }
}
