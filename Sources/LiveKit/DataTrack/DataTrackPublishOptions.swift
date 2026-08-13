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

/// Options for publishing a data track via
/// ``LocalParticipant/publishDataTrack(name:options:)``.
@objc
public final class DataTrackPublishOptions: NSObject, Sendable {
    /// Schema describing the track's frames.
    @objc public let schema: DataTrackSchemaId?
    /// Encoding of the track's frames.
    @nonobjc public let frameEncoding: DataTrackFrameEncoding?
    /// The frame encoding as its identifier string; Objective-C sees this as `frameEncoding`.
    @objc(frameEncoding) public var frameEncodingIdentifier: String? { frameEncoding?.identifier }

    /// Declares the frame encoding without a schema.
    public init(frameEncoding: DataTrackFrameEncoding) {
        schema = nil
        self.frameEncoding = frameEncoding
        super.init()
    }

    /// Declares a schema; a schema always describes frames in a specific encoding, so one is
    /// required alongside it.
    public init(schema: DataTrackSchemaId, frameEncoding: DataTrackFrameEncoding) {
        self.schema = schema
        self.frameEncoding = frameEncoding
        super.init()
    }

    /// Objective-C entry point; `frameEncoding` identifiers not naming a well-known encoding are
    /// treated as application-specific (custom).
    @objc(initWithSchema:frameEncoding:)
    public convenience init(schema: DataTrackSchemaId?, frameEncodingIdentifier: String) {
        let frameEncoding = DataTrackFrameEncoding(identifier: frameEncodingIdentifier)
        if let schema {
            self.init(schema: schema, frameEncoding: frameEncoding)
        } else {
            self.init(frameEncoding: frameEncoding)
        }
    }
}
