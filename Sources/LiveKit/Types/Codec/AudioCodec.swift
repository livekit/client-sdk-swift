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
public final class AudioCodec: NSObject, Codec {
    public static func from(name: String) -> AudioCodec? {
        guard let codec = all.first(where: { $0.name == name.lowercased() }) else { return nil }
        return codec
    }

    public static func from(mimeType: String) -> AudioCodec? {
        let parts = mimeType.lowercased().split(separator: "/")
        guard parts.count >= 2, parts[0] == "audio" else { return nil }
        return from(name: String(parts[1]))
    }

    public static let opus = AudioCodec(name: "opus")
    public static let red = AudioCodec(name: "red")

    public static let all: [AudioCodec] = [opus, red]

    public let mediaType = "audio"
    public let name: String

    init(name: String) {
        self.name = name
    }
}
