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
@objc(DataTrackSchemaId)
public final class DataTrackSchemaId: NSObject, Sendable {
    /// Schema name, unique within the room.
    @objc public let name: String
    /// Encoding of the schema definition itself.
    public let encoding: DataTrackSchemaEncoding
    /// The encoding as its identifier string; Objective-C sees this as `encoding`.
    @objc(encoding) public var encodingIdentifier: String { encoding.identifier }

    /// Creates a schema identifier from its name and the encoding of the schema definition.
    public init(name: String, encoding: DataTrackSchemaEncoding) {
        self.name = name
        self.encoding = encoding
        super.init()
    }

    /// Objective-C entry point; `encoding` identifiers not naming a well-known encoding are
    /// treated as application-specific (custom).
    @objc(initWithName:encoding:)
    public convenience init(name: String, encodingIdentifier: String) {
        self.init(name: name, encoding: DataTrackSchemaEncoding(identifier: encodingIdentifier))
    }

    init(_ ffi: LiveKitUniFFI.DataTrackSchemaId) {
        name = ffi.name
        encoding = DataTrackSchemaEncoding(ffi.encoding)
        super.init()
    }

    var ffi: LiveKitUniFFI.DataTrackSchemaId {
        LiveKitUniFFI.DataTrackSchemaId(name: name, encoding: encoding.ffi)
    }

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return name == other.name && encoding == other.encoding
    }

    override public var hash: Int {
        var hasher = Hasher()
        name.hash(into: &hasher)
        encoding.hash(into: &hasher)
        return hasher.finalize()
    }

    override public var description: String {
        "\(name) (\(encoding.identifier))"
    }
}

/// Encoding of a data track schema definition.
public enum DataTrackSchemaEncoding: Sendable, Equatable, Hashable {
    /// Protocol Buffers schema (`.proto`), describing `protobuf`-encoded frames.
    case protobuf
    /// FlatBuffers schema (`.fbs`), describing `flatbuffer`-encoded frames.
    case flatbuffer
    /// ROS 1 message definition, describing `ros1`-encoded frames.
    case ros1Msg
    /// ROS 2 message definition, describing `cdr`-encoded frames.
    case ros2Msg
    /// ROS 2 IDL definition, describing `cdr`-encoded frames.
    case ros2Idl
    /// OMG IDL definition, describing `cdr`-encoded frames.
    case omgIdl
    /// JSON Schema, describing `json`-encoded frames.
    case jsonSchema
    /// Another well-known encoding not known to this client version.
    case other
    /// An application-specific encoding identified by the contained string.
    case custom(String)

    /// Stable string form, used as the Objective-C representation. Identifiers naming a
    /// well-known encoding always map to that case, so a custom encoding cannot shadow one.
    public var identifier: String {
        switch self {
        case .protobuf: "protobuf"
        case .flatbuffer: "flatbuffer"
        case .ros1Msg: "ros1msg"
        case .ros2Msg: "ros2msg"
        case .ros2Idl: "ros2idl"
        case .omgIdl: "omgidl"
        case .jsonSchema: "jsonschema"
        case .other: "other"
        case let .custom(identifier): identifier
        }
    }

    /// Creates an encoding from its ``identifier``; unrecognized identifiers become ``custom(_:)``.
    public init(identifier: String) {
        switch identifier {
        case "protobuf": self = .protobuf
        case "flatbuffer": self = .flatbuffer
        case "ros1msg": self = .ros1Msg
        case "ros2msg": self = .ros2Msg
        case "ros2idl": self = .ros2Idl
        case "omgidl": self = .omgIdl
        case "jsonschema": self = .jsonSchema
        case "other": self = .other
        default: self = .custom(identifier)
        }
    }

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

    var ffi: LiveKitUniFFI.DataTrackSchemaEncoding {
        switch self {
        case .protobuf: .protobuf
        case .flatbuffer: .flatbuffer
        case .ros1Msg: .ros1Msg
        case .ros2Msg: .ros2Msg
        case .ros2Idl: .ros2Idl
        case .omgIdl: .omgIdl
        case .jsonSchema: .jsonSchema
        case .other: .other
        case let .custom(identifier): .custom(identifier)
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

    /// Stable string form, used as the Objective-C representation. Identifiers naming a
    /// well-known encoding always map to that case, so a custom encoding cannot shadow one.
    public var identifier: String {
        switch self {
        case .ros1: "ros1"
        case .cdr: "cdr"
        case .protobuf: "protobuf"
        case .flatbuffer: "flatbuffer"
        case .cbor: "cbor"
        case .msgpack: "msgpack"
        case .json: "json"
        case .other: "other"
        case let .custom(identifier): identifier
        }
    }

    /// Creates an encoding from its ``identifier``; unrecognized identifiers become ``custom(_:)``.
    public init(identifier: String) {
        switch identifier {
        case "ros1": self = .ros1
        case "cdr": self = .cdr
        case "protobuf": self = .protobuf
        case "flatbuffer": self = .flatbuffer
        case "cbor": self = .cbor
        case "msgpack": self = .msgpack
        case "json": self = .json
        case "other": self = .other
        default: self = .custom(identifier)
        }
    }

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

    var ffi: LiveKitUniFFI.DataTrackFrameEncoding {
        switch self {
        case .ros1: .ros1
        case .cdr: .cdr
        case .protobuf: .protobuf
        case .flatbuffer: .flatbuffer
        case .cbor: .cbor
        case .msgpack: .msgpack
        case .json: .json
        case .other: .other
        case let .custom(identifier): .custom(identifier)
        }
    }
}
