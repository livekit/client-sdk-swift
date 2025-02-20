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

public typealias ByteStreamHandler = (ByteStreamReader, Participant.Identity) async throws -> Void
public typealias TextStreamHandler = (TextStreamReader, Participant.Identity) async throws -> Void

/// Manages state of incoming data streams.
actor IncomingStreamManager: Loggable {
    
    private struct OpenStream {
        let info: StreamInfo
        var readLength: Int = 0
        let openTime: TimeInterval
        let continuation: StreamReaderSource.Continuation
    }
    
    private var openStreams: [String: OpenStream] = [:]
    
    private var byteStreamHandlers: [String: ByteStreamHandler] = [:]
    private var textStreamHandlers: [String: TextStreamHandler] = [:]
    
    // MARK: - Handler registration
    
    func registerByteStreamHandler(for topic: String, _ handler: @escaping ByteStreamHandler) throws {
        guard byteStreamHandlers[topic] == nil else {
            throw StreamError.handlerAlreadyRegistered
        }
        byteStreamHandlers[topic] = handler
    }
    
    func registerTextStreamHandler(for topic: String, _ handler: @escaping TextStreamHandler) throws {
        guard textStreamHandlers[topic] == nil else {
            throw StreamError.handlerAlreadyRegistered
        }
        textStreamHandlers[topic] = handler
    }
    
    func unregisterByteStreamHandler(for topic: String) {
        byteStreamHandlers[topic] = nil
    }
    
    func unregisterTextStreamHandler(for topic: String) {
        textStreamHandlers[topic] = nil
    }
    
    // MARK: - State
    
    private func openStream(
        with info: StreamInfo,
        continuation: StreamReaderSource.Continuation
    ) {
        guard openStreams[info.id] == nil else {
            continuation.finish(throwing: StreamError.alreadyOpened)
            return
        }
        continuation.onTermination = { @Sendable [weak self] termination in
            guard let self else { return }
            self.log("Continuation terminated: \(termination)", .debug)
            Task { await self.closeStream(with: info.id) }
        }
        let descriptor = OpenStream(
            info: info,
            openTime: Date.timeIntervalSinceReferenceDate,
            continuation: continuation
        )
        log("Opened stream '\(info.id)'", .debug)
        openStreams[info.id] = descriptor
    }
    
    private func closeStream(with id: String) {
        guard let descriptor = openStreams[id] else {
            log("No descriptor for stream '\(id)'", .debug)
            return
        }
        let openDuration = Date.timeIntervalSinceReferenceDate - descriptor.openTime
        log("Closed stream '\(id)' (open for \(openDuration))", .debug)
        openStreams[id] = nil
    }
    
    // MARK: - Packet processing
    
    /// Handles a data stream header.
    func handle(header: Livekit_DataStream.Header, from identityString: String) {
        let identity = Participant.Identity(from: identityString)
        
        switch header.contentHeader {
        case .byteHeader(let byteHeader):
            guard let handler = byteStreamHandlers[header.topic] else {
                log("No byte handler registered for topic '\(header.topic)'", .info)
                return
            }
            let info = ByteStreamInfo(header, byteHeader)
            let reader = ByteStreamReader(info: info, source: createSource(with: info))
            Task {
                do { try await handler(reader, identity) }
                catch { log("Unhandled error in byte stream handler: \(error)", .error) }
            }
            
        case .textHeader(let textHeader):
            guard let handler = textStreamHandlers[header.topic] else {
                log("No text handler registered for topic '\(header.topic)'", .info)
                return
            }
            let info = TextStreamInfo(header, textHeader)
            let reader = TextStreamReader(info: info, source: createSource(with: info))
            Task {
                do { try await handler(reader, identity) }
                catch { log("Unhandled error in text stream handler: \(error)", .error) }
            }
        default:
            log("Unknown header type; ignoring stream", .warning)
            
        }
    }
    
    /// Creates an asynchronous stream whose continuation will be used to send new chunks to the reader.
    private func createSource(with info: StreamInfo) -> StreamReaderSource {
        StreamReaderSource { [weak self] continuation in
            guard let self else {
                continuation.finish(throwing: StreamError.terminated)
                return
            }
            Task { await self.openStream(with: info, continuation: continuation) }
        }
    }
    
    /// Handles a data stream chunk.
    func handle(chunk: Livekit_DataStream.Chunk) {
        guard !chunk.content.isEmpty, let descriptor = openStreams[chunk.streamID] else { return }
        
        let readLength = descriptor.readLength + chunk.content.count
        
        if let totalLength = descriptor.info.totalLength {
            guard readLength <= totalLength else {
                descriptor.continuation.finish(throwing: StreamError.lengthExceeded)
                return
            }
        }
        openStreams[chunk.streamID]!.readLength = readLength
        descriptor.continuation.yield(chunk.content)
    }
    
    /// Handles a data stream trailer.
    func handle(trailer: Livekit_DataStream.Trailer) {
        guard let descriptor = openStreams[trailer.streamID] else {
            log("Received trailer for unknown stream '\(trailer.streamID)'", .warning)
            return
        }
        
        if let totalLength = descriptor.info.totalLength {
            guard descriptor.readLength == totalLength else {
                descriptor.continuation.finish(throwing: StreamError.incomplete)
                return
            }
        }
        
        // TODO: do something with trailer attributes
        
        guard trailer.reason.isEmpty else {
            // According to protocol documentation, a non-empty reason string indicates an error
            let error = StreamError.abnormalEnd(reason: trailer.reason)
            descriptor.continuation.finish(throwing: error)
            return
        }
        descriptor.continuation.finish()
    }
    
    // MARK: - Clean up
    
    deinit {
        guard !openStreams.isEmpty else { return }
        log("Terminating \(openStreams.count) open stream(s)", .debug)
        for descriptor in openStreams.values {
            descriptor.continuation.finish(throwing: StreamError.terminated)
        }
    }
}
