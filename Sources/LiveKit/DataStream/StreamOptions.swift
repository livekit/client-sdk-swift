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

    public let version: Int
    public let attachedStreamIDs: [String]
    public let replyToStreamID: String?

    // TODO: Expose additional protocol level fields

    public init(
        topic: String,
        attributes: [String: String] = [:],
        destinationIdentities: [Participant.Identity] = [],
        id: String? = nil,
        version: Int = 0,
        attachedStreamIDs: [String] = [],
        replyToStreamID: String? = nil
    ) {
        self.topic = topic
        self.attributes = attributes
        self.destinationIdentities = destinationIdentities
        self.id = id
        self.version = version
        self.attachedStreamIDs = attachedStreamIDs
        self.replyToStreamID = replyToStreamID
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
    public let totalSize: Int?

    public init(
        topic: String,
        attributes: [String: String] = [:],
        destinationIdentities: [Participant.Identity] = [],
        id: String? = nil,
        mimeType: String? = nil,
        name: String? = nil,
        totalSize: Int? = nil
    ) {
        self.topic = topic
        self.attributes = attributes
        self.destinationIdentities = destinationIdentities
        self.id = id
        self.mimeType = mimeType
        self.name = name
        self.totalSize = totalSize
    }
}
