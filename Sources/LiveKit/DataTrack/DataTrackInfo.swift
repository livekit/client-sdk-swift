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

/// Metadata describing a published data track.
@objcMembers
public final class DataTrackInfo: NSObject, Sendable {
    /// Server-assigned unique identifier for the track.
    public let sid: DataTrack.Sid
    /// Name chosen by the publisher; unique per participant.
    public let name: String
    /// Whether the track's frames are end-to-end encrypted.
    public let usesE2ee: Bool
    /// Schema describing the track's frames, if the publisher declared one.
    public let schema: DataTrackSchemaId?
    /// Encoding of the track's frames, if the publisher declared one.
    @nonobjc public let frameEncoding: DataTrackFrameEncoding?
    /// The frame encoding as its identifier string; Objective-C sees this as `frameEncoding`.
    @objc(frameEncoding) public var frameEncodingIdentifier: String? { frameEncoding?.identifier }

    init(_ info: LiveKitUniFFI.DataTrackInfo) {
        sid = DataTrack.Sid(from: info.sid)
        name = info.name
        usesE2ee = info.usesE2ee
        schema = info.schema.map(DataTrackSchemaId.init)
        frameEncoding = info.frameEncoding.map(DataTrackFrameEncoding.init)
        super.init()
    }

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return sid == other.sid && name == other.name && usesE2ee == other.usesE2ee
            && schema == other.schema && frameEncoding == other.frameEncoding
    }

    override public var hash: Int {
        var hasher = Hasher()
        sid.hash(into: &hasher)
        name.hash(into: &hasher)
        usesE2ee.hash(into: &hasher)
        schema.hash(into: &hasher)
        frameEncoding.hash(into: &hasher)
        return hasher.finalize()
    }
}
