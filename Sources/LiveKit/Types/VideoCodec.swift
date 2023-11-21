/*
 * Copyright 2023 LiveKit
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

@objc
public class BackupVideoCodec: NSObject {
    public class var h264: BackupVideoCodec { BackupVideoCodec(id: "h264") }
    public class var vp8: BackupVideoCodec { BackupVideoCodec(id: "vp8") }

    // codec Id
    public let id: String

    // Internal only
    init(id: String) {
        self.id = id
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return id == other.id
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        return hasher.finalize()
    }
}

@objc
public class VideoCodec: BackupVideoCodec {
    override public class var h264: VideoCodec { VideoCodec(id: "h264") }
    override public class var vp8: VideoCodec { VideoCodec(id: "vp8") }
    public class var vp9: VideoCodec { VideoCodec(id: "vp9") }
    public class var av1: VideoCodec { VideoCodec(id: "av1") }
}
