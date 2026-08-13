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

internal import LiveKitUniFFI

/// Identifies the schema describing a data track's frames.
public struct DataTrackSchemaId: Sendable, Equatable, Hashable {
    /// Schema name, unique within the room.
    public let name: String
    /// Encoding of the schema definition itself.
    public let encoding: DataTrackSchemaEncoding

    init(_ ffi: LiveKitUniFFI.DataTrackSchemaId) {
        name = ffi.name
        encoding = DataTrackSchemaEncoding(ffi.encoding)
    }
}

/// Encoding of a data track schema definition.
public enum DataTrackSchemaEncoding: Sendable, Equatable, Hashable {
    case protobuf
    case flatbuffer
    case ros1Msg
    case ros2Msg
    case ros2Idl
    case omgIdl
    case jsonSchema
    /// Another well-known encoding not known to this client version.
    case other
    /// An application-specific encoding identified by the contained string.
    case custom(String)

    init(_ ffi: LiveKitUniFFI.DataTrackSchemaEncoding) {
        switch ffi {
        case .protobuf: self = .protobuf
        case .flatbuffer: self = .flatbuffer
        case .ros1Msg: self = .ros1Msg
        case .ros2Msg: self = .ros2Msg
        case .ros2Idl: self = .ros2Idl
        case .omgIdl: self = .omgIdl
        case .jsonSchema: self = .jsonSchema
        case .other: self = .other
        case let .custom(identifier): self = .custom(identifier)
        @unknown default: self = .other
        }
    }
}

/// Encoding of the frames sent over a data track.
public enum DataTrackFrameEncoding: Sendable, Equatable, Hashable {
    /// ROS 1.
    case ros1
    /// CDR (ROS 2 / OMG IDL).
    case cdr
    /// Protocol Buffers.
    case protobuf
    /// FlatBuffers.
    case flatbuffer
    /// CBOR, self-describing.
    case cbor
    /// MessagePack, self-describing.
    case msgpack
    /// JSON, self-describing.
    case json
    /// Another well-known encoding not known to this client version.
    case other
    /// An application-specific encoding identified by the contained string.
    case custom(String)

    init(_ ffi: LiveKitUniFFI.DataTrackFrameEncoding) {
        switch ffi {
        case .ros1: self = .ros1
        case .cdr: self = .cdr
        case .protobuf: self = .protobuf
        case .flatbuffer: self = .flatbuffer
        case .cbor: self = .cbor
        case .msgpack: self = .msgpack
        case .json: self = .json
        case .other: self = .other
        case let .custom(identifier): self = .custom(identifier)
        @unknown default: self = .other
        }
    }
}
