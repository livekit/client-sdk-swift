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

/// Manages state of outgoing data streams.
actor OutgoingStreamManager: Loggable {
    typealias PacketHandler = (Livekit_DataPacket) async throws -> Void
    
    private nonisolated let packetHandler: PacketHandler
    
    init(packetHandler: @escaping PacketHandler) {
        self.packetHandler = packetHandler
    }
    
    /// Information about an open data stream.
    private struct Descriptor {
        let info: StreamInfo
        var writtenLength: Int = 0
        var chunkIndex: UInt64 = 0
    }
    
    /// Mapping between stream ID and descriptor for open streams.
    private var openStreams: [String: Descriptor] = [:]
    
    private func hasOpenStream(for streamID: String) -> Bool {
        openStreams[streamID] != nil
    }
    
    private func open(with streamInfo: StreamInfo) async throws {
        guard openStreams[streamInfo.id] == nil else {
            throw StreamError.alreadyOpened
        }
        
        let header = Livekit_DataStream.Header(streamInfo)
        let packet = Livekit_DataPacket.with {
            $0.value = .streamHeader(header)
        }
        
        try await packetHandler(packet)
        
        let descriptor = Descriptor(info: streamInfo)
        openStreams[streamInfo.id] = descriptor
    }
    
    private func sendChunk(data: Data, streamID: String) async throws {
        guard let descriptor = openStreams[streamID] else {
            throw StreamError.unknownStream
        }
        let chunk = Livekit_DataStream.Chunk.with {
            $0.streamID = streamID
            $0.chunkIndex = descriptor.chunkIndex
            $0.content = data
        }
        let packet = Livekit_DataPacket.with {
            $0.value = .streamChunk(chunk)
        }
        try await packetHandler(packet)
        
        openStreams[streamID]!.writtenLength += data.count
        openStreams[streamID]!.chunkIndex += 1
    }
    
    private func close(reason: String?, streamID: String) async throws {
        guard openStreams[streamID] != nil else {
            throw StreamError.unknownStream
        }
        
        let trailer = Livekit_DataStream.Trailer.with {
            $0.streamID = streamID
            $0.reason = reason ?? ""
        }
        let packet = Livekit_DataPacket.with {
            $0.value = .streamTrailer(trailer)
        }
        
        try await packetHandler(packet)
        
        openStreams[streamID] = nil
    }

    fileprivate struct Destination: StreamWriterDestination {
        let streamID: String
        weak var manager: OutgoingStreamManager?
        
        var isOpen: Bool {
            get async {
                guard let manager else { return false }
                return await manager.hasOpenStream(for: streamID)
            }
        }
        
        func sendChunk(data: Data) async throws {
            guard let manager else { throw StreamError.terminated }
            try await manager.sendChunk(data: data, streamID: streamID)
        }
        
        func close(reason: String? = nil) async throws {
            guard let manager else { throw StreamError.terminated }
            try? await manager.close(reason: reason, streamID: streamID)
        }
    }
    
    /// Opens a text stream with the given options, returning a writer.
    func streamText(options: StreamTextOptions) async throws -> TextStreamWriter {
        let info = TextStreamInfo(
            id: options.id ?? UUID().uuidString,
            mimeType: Self.textMimeType,
            topic: options.topic,
            timestamp: Date(),
            totalLength: nil,
            attributes: options.attributes ?? [:],
            operationType: .create,
            version: options.version ?? 0,
            replyToStreamID: options.replyToStreamID,
            attachedStreamIDs: options.attachedStreamIDs ?? [],
            generated: false
        )

        try await open(with: info)
        
        return TextStreamWriter(
            info: info,
            destination: Destination(streamID: info.id, manager: self)
        )
    }
    
    /// Opens a byte stream with the given options, returning a writer.
    func streamBytes(options: StreamByteOptions) async throws -> ByteStreamWriter {
        let info = ByteStreamInfo(
            id: options.id ?? UUID().uuidString,
            mimeType: options.mimeType ?? Self.byteMimeType,
            topic: options.topic,
            timestamp: Date(),
            totalLength: options.totalSize,
            attributes: options.attributes ?? [:],
            name: options.name
        )
        try await open(with: info)

        return ByteStreamWriter(
            info: info,
            destination: Destination(streamID: info.id, manager: self)
        )
    }
    
    /// Default MIME type to use for text streams.
    private static let textMimeType = "text/plain"
    
    /// Default MIME type to use for byte streams.
    private static let byteMimeType = "application/octet-stream"
}
