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

@objc
public final class VideoCodec: NSObject, Codec {
    public static func from(name: String) -> VideoCodec? {
        guard let codec = all.first(where: { $0.name == name.lowercased() }) else { return nil }
        return codec
    }

    public static func from(mimeType: String) -> VideoCodec? {
        let parts = mimeType.lowercased().split(separator: "/")
        guard parts.count >= 2, parts[0] == "video" else { return nil }
        return from(name: String(parts[1]))
    }

    public static let h264 = VideoCodec(name: "h264", isBackup: true)
    public static let vp8 = VideoCodec(name: "vp8", isBackup: true)
    public static let vp9 = VideoCodec(name: "vp9", isSVC: true)
    public static let av1 = VideoCodec(name: "av1", isSVC: true)
    public static let h265 = VideoCodec(name: "h265", isBackup: false)

    public static let all: [VideoCodec] = [.h264, .h265, .vp8, .vp9, .av1]
    public static let allBackup: [VideoCodec] = [.h264, .vp8]

    public let mediaType = "video"
    // Name of the codec such as "vp8".
    public let name: String
    // Whether the codec can be used as `backup`
    public let isBackup: Bool
    // Whether the codec is an SVC codec.
    public let isSVC: Bool

    // Internal only
    init(name: String,
         isBackup: Bool = false,
         isSVC: Bool = false)
    {
        self.name = name
        self.isBackup = isBackup
        self.isSVC = isSVC
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return name == other.name
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(name)
        return hasher.finalize()
    }

    override public var description: String {
        "VideoCodec(name: \(name))"
    }
}

extension Livekit_SubscribedCodec {
    func toVideoCodec() -> VideoCodec? {
        VideoCodec.from(name: codec)
    }
}
