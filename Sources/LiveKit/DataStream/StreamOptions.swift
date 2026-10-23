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

internal import LiveKitFFI

/// Options used when opening an outgoing data stream.
public protocol StreamOptions: Sendable {
    /// Topic name used to route the stream to the appropriate handler.
    var topic: String { get }

    /// Additional attributes as needed for your application.
    var attributes: [String: String] { get }

    /// Identities of the participants to send the stream to. If empty, will be sent to all.
    var destinationIdentities: [Participant.Identity] { get }

    /// Explicitly set unique identifier of the stream.
    var id: String? { get }
}

/// Options used when opening an outgoing text data stream.
@objcMembers
public final class StreamTextOptions: NSObject, StreamOptions {
    public let topic: String
    public let attributes: [String: String]
    public let destinationIdentities: [Participant.Identity]
    public let id: String?

    /// What the stream does to the message it refers to, for example
    /// ``TextStreamInfo/OperationType/update`` to edit an earlier one. `.create` by default.
    public let operationType: TextStreamInfo.OperationType

    public let version: Int
    public let attachedStreamIDs: [String]
    public let replyToStreamID: String?

    /// Whether a machine generated the text, for example an AI agent's transcription, rather than
    /// a person typing it. Receivers read it as ``TextStreamInfo/generated``. `false` by default.
    public let generated: Bool

    /// Whether a one-shot send (`sendText`, `sendBytes` or `sendFile`) compresses the payload.
    /// `true` by default. The payload goes out uncompressed when a recipient can't decompress it.
    /// A stream opened with `streamText` or `streamBytes` is never compressed, because its content
    /// is not known up front.
    public let compress: Bool

    /// Sends the stream on behalf of another identity, which receivers then see as its sender.
    /// `nil` (the default) sends as the local participant.
    ///
    /// - Note: The server decides whether this participant may send on behalf of another identity.
    ///   A server that does not allow it, such as `livekit-server --dev`, delivers the stream as
    ///   the local participant's.
    public let senderIdentity: Participant.Identity?

    // TODO: Expose additional protocol level fields

    public init(
        topic: String,
        attributes: [String: String] = [:],
        destinationIdentities: [Participant.Identity] = [],
        id: String? = nil,
        operationType: TextStreamInfo.OperationType = .create,
        version: Int = 0,
        attachedStreamIDs: [String] = [],
        replyToStreamID: String? = nil,
        generated: Bool = false,
        compress: Bool = true,
        senderIdentity: Participant.Identity? = nil,
    ) {
        self.topic = topic
        self.attributes = attributes
        self.destinationIdentities = destinationIdentities
        self.id = id
        self.operationType = operationType
        self.version = version
        self.attachedStreamIDs = attachedStreamIDs
        self.replyToStreamID = replyToStreamID
        self.generated = generated
        self.compress = compress
        self.senderIdentity = senderIdentity
    }

    var ffi: LiveKitFFI.StreamTextOptions {
        LiveKitFFI.StreamTextOptions(
            topic: topic,
            attributes: attributes,
            destinationIdentities: destinationIdentities.map(\.stringValue),
            id: id,
            operationType: operationType.ffiValue,
            version: Int32(truncatingIfNeeded: version),
            replyToStreamId: replyToStreamID,
            attachedStreamIds: attachedStreamIDs,
            generated: generated,
            compress: compress,
            senderIdentity: senderIdentity?.stringValue,
        )
    }

    /// A copy that also lists `ids` in ``attachedStreamIDs``.
    func attaching(_ ids: [String]) -> StreamTextOptions {
        StreamTextOptions(
            topic: topic,
            attributes: attributes,
            destinationIdentities: destinationIdentities,
            id: id,
            operationType: operationType,
            version: version,
            attachedStreamIDs: attachedStreamIDs + ids,
            replyToStreamID: replyToStreamID,
            generated: generated,
            compress: compress,
            senderIdentity: senderIdentity,
        )
    }

    /// The initializer without `compress`, which defaults to `true`. Keeps code and binaries built
    /// against the earlier signature working.
    public convenience init(
        topic: String,
        attributes: [String: String] = [:],
        destinationIdentities: [Participant.Identity] = [],
        id: String? = nil,
        version: Int = 0,
        attachedStreamIDs: [String] = [],
        replyToStreamID: String? = nil,
    ) {
        self.init(
            topic: topic,
            attributes: attributes,
            destinationIdentities: destinationIdentities,
            id: id,
            version: version,
            attachedStreamIDs: attachedStreamIDs,
            replyToStreamID: replyToStreamID,
            compress: true,
        )
    }
}

/// Options used when opening an outgoing byte data stream.
@objcMembers
public final class StreamByteOptions: NSObject, StreamOptions {
    public let topic: String
    public let attributes: [String: String]
    public let destinationIdentities: [Participant.Identity]
    public let id: String?

    /// Explicitly set MIME type of the stream data. Auto-detected for files, otherwise
    /// defaults to `application/octet-stream`.
    public let mimeType: String?

    /// The name of the file being sent.
    public let name: String?

    /// Total expected size in bytes, if known.
    ///
    /// - Note: A negative value is treated as `nil` — the size is simply not declared, rather than
    ///   trapping on the conversion to the wire's unsigned length.
    public let totalSize: Int?

    /// Whether a one-shot send (`sendText`, `sendBytes` or `sendFile`) compresses the payload.
    /// `true` by default. The payload goes out uncompressed when a recipient can't decompress it.
    /// A stream opened with `streamText` or `streamBytes` is never compressed, because its content
    /// is not known up front.
    public let compress: Bool

    /// Sends the stream on behalf of another identity, which receivers then see as its sender.
    /// `nil` (the default) sends as the local participant.
    ///
    /// - Note: The server decides whether this participant may send on behalf of another identity.
    ///   A server that does not allow it, such as `livekit-server --dev`, delivers the stream as
    ///   the local participant's.
    public let senderIdentity: Participant.Identity?

    public init(
        topic: String,
        attributes: [String: String] = [:],
        destinationIdentities: [Participant.Identity] = [],
        id: String? = nil,
        mimeType: String? = nil,
        name: String? = nil,
        totalSize: Int? = nil,
        compress: Bool = true,
        senderIdentity: Participant.Identity? = nil,
    ) {
        self.topic = topic
        self.attributes = attributes
        self.destinationIdentities = destinationIdentities
        self.id = id
        self.mimeType = mimeType
        self.name = name
        self.totalSize = totalSize.flatMap { $0 >= 0 ? $0 : nil }
        self.compress = compress
        self.senderIdentity = senderIdentity
    }

    var ffi: LiveKitFFI.StreamByteOptions {
        LiveKitFFI.StreamByteOptions(
            topic: topic,
            attributes: attributes,
            destinationIdentities: destinationIdentities.map(\.stringValue),
            id: id,
            mimeType: mimeType,
            name: name,
            totalLength: totalSize.map { UInt64($0) },
            compress: compress,
            senderIdentity: senderIdentity?.stringValue,
        )
    }

    /// The initializer without `compress`, which defaults to `true`. Keeps code and binaries built
    /// against the earlier signature working.
    public convenience init(
        topic: String,
        attributes: [String: String] = [:],
        destinationIdentities: [Participant.Identity] = [],
        id: String? = nil,
        mimeType: String? = nil,
        name: String? = nil,
        totalSize: Int? = nil,
    ) {
        self.init(
            topic: topic,
            attributes: attributes,
            destinationIdentities: destinationIdentities,
            id: id,
            mimeType: mimeType,
            name: name,
            totalSize: totalSize,
            compress: true,
        )
    }

    /// ObjC-compatible initializer without `compress`, which defaults to `true`. Keeps code and
    /// binaries built against the earlier signature working.
    @available(*, deprecated, message: "Use init(topic:attributes:destinationIdentities:id:mimeType:name:totalSize:) instead.")
    public convenience init(
        topic: String,
        attributes: [String: String],
        destinationIdentities: [Participant.Identity],
        id: String?,
        mimeType: String?,
        name: String?,
        totalSizeNumber: NSNumber?,
    ) {
        self.init(
            topic: topic,
            attributes: attributes,
            destinationIdentities: destinationIdentities,
            id: id,
            mimeType: mimeType,
            name: name,
            totalSize: totalSizeNumber?.intValue,
            compress: true,
        )
    }

    /// ObjC-compatible initializer that accepts `NSNumber?` for `totalSize`.
    ///
    /// Required because `Int?` does not auto-bridge to ObjC.

    @available(*, deprecated, message: "Use init(topic:attributes:destinationIdentities:id:mimeType:name:totalSize:) instead.")
    public convenience init(
        topic: String,
        attributes: [String: String],
        destinationIdentities: [Participant.Identity],
        id: String?,
        mimeType: String?,
        name: String?,
        totalSizeNumber: NSNumber?,
        compress: Bool = true,
    ) {
        self.init(
            topic: topic,
            attributes: attributes,
            destinationIdentities: destinationIdentities,
            id: id,
            mimeType: mimeType,
            name: name,
            totalSize: totalSizeNumber?.intValue,
            compress: compress,
        )
    }
}
