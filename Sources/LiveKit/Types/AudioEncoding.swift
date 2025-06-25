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

internal import LiveKitWebRTC

@objc
public final class AudioEncoding: NSObject, MediaEncoding, Sendable {
    @objc
    public let maxBitrate: Int

    @objc
    public init(maxBitrate: Int) {
        self.maxBitrate = maxBitrate
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return maxBitrate == other.maxBitrate
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(maxBitrate)
        return hasher.finalize()
    }
}

// MARK: - Presets

@objc
public extension AudioEncoding {
    internal static let presets = [
        presetTelephone,
        presetSpeech,
        presetMusic,
        presetMusicStereo,
        presetMusicHighQuality,
        presetMusicHighQualityStereo,
    ]

    static let presetTelephone = AudioEncoding(maxBitrate: 12000)
    static let presetSpeech = AudioEncoding(maxBitrate: 24000)
    static let presetMusic = AudioEncoding(maxBitrate: 48000)
    static let presetMusicStereo = AudioEncoding(maxBitrate: 64000)
    static let presetMusicHighQuality = AudioEncoding(maxBitrate: 96000)
    static let presetMusicHighQualityStereo = AudioEncoding(maxBitrate: 128_000)
}
