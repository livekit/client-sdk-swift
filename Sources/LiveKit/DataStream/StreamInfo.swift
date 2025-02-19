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

/// Information about a data stream.
protocol StreamInfo {
    var id: String { get }
    var mimeType: String { get }
    var topic: String { get }
    var timestamp: Date { get }
    var totalLength: Int? { get }
    var attributes: [String: String] { get }
}

/// Information about a text data stream.
@objcMembers
public final class TextStreamInfo: NSObject, StreamInfo, Sendable {
    public let id: String
    public let mimeType: String
    public let topic: String
    public let timestamp: Date
    public let totalLength: Int?
    public let attributes: [String : String]

    @objc(TextStreamInfoOperationType)
    public enum OperationType: Int, Sendable {
        case create
        case update
        case delete
        case reaction
    }

    public let operationType: OperationType
    public let version: Int
    public let replyToStreamID: String?
    public let attachedStreamIDs: [String]
    public let generated: Bool

    init(
        id: String,
        mimeType: String,
        topic: String,
        timestamp: Date,
        totalLength: Int?,
        attributes: [String: String],
        operationType: OperationType,
        version: Int,
        replyToStreamID: String?,
        attachedStreamIDs: [String],
        generated: Bool
    ) {
        self.id = id
        self.mimeType = mimeType
        self.topic = topic
        self.timestamp = timestamp
        self.totalLength = totalLength
        self.attributes = attributes
        self.operationType = operationType
        self.version = version
        self.replyToStreamID = replyToStreamID
        self.attachedStreamIDs = attachedStreamIDs
        self.generated = generated
    }
}

/// Information about a byte data stream.
@objcMembers
public final class ByteStreamInfo: NSObject, StreamInfo, Sendable {
    public let id: String
    public let mimeType: String
    public let topic: String
    public let timestamp: Date
    public let totalLength: Int?
    public let attributes: [String: String]

    public let fileName: String?

    init(
        id: String,
        mimeType: String,
        topic: String,
        timestamp: Date,
        totalLength: Int?,
        attributes: [String: String],
        fileName: String?
    ) {
        self.id = id
        self.mimeType = mimeType
        self.topic = topic
        self.timestamp = timestamp
        self.totalLength = totalLength
        self.attributes = attributes
        self.fileName = fileName
    }
}

// MARK: - Computed properties

extension ByteStreamInfo {
    
    /// Extension to use if MIME type is not set or is invalid.
    private static let fallbackExtension = "bin"
    
    /// Default file extension.
    var defaultExtension: String {
        preferredExtension(for: mimeType) ?? Self.fallbackExtension
    }
    
    /// Default file name.
    func defaultFileName(override: String? = nil) -> String {
        guard let fileName = override ?? fileName else {
            return "\(id).\(defaultExtension)"
        }
        guard fileName.pathExtension != nil else {
            return "\(fileName).\(defaultExtension)"
        }
        return fileName
    }
}

// MARK: - From protocol types

extension ByteStreamInfo {
    convenience init(
        _ header: Livekit_DataStream.Header,
        _ byteHeader: Livekit_DataStream.ByteHeader
    ) {
        self.init(
            id: header.streamID,
            mimeType: header.mimeType,
            topic: header.topic,
            timestamp: Date(timeIntervalSince1970: TimeInterval(header.timestamp)),
            totalLength: header.hasTotalLength ? Int(header.totalLength) : nil,
            attributes: header.attributes,
            // ---
            fileName: byteHeader.name
        )
    }
}

extension TextStreamInfo {
    convenience init(
        _ header: Livekit_DataStream.Header,
        _ textHeader: Livekit_DataStream.TextHeader
    ) {
        self.init(
            id: header.streamID,
            mimeType: header.mimeType,
            topic: header.topic,
            timestamp: Date(timeIntervalSince1970: TimeInterval(header.timestamp)),
            totalLength: header.hasTotalLength ? Int(header.totalLength) : nil,
            attributes: header.attributes,
            // ---
            operationType: TextStreamInfo.OperationType(rawValue: textHeader.operationType.rawValue) ?? .create,
            version: Int(textHeader.version),
            replyToStreamID: !textHeader.replyToStreamID.isEmpty ? textHeader.replyToStreamID : nil,
            attachedStreamIDs: textHeader.attachedStreamIds,
            generated: textHeader.generated
        )
    }
}
