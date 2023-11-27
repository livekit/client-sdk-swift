/*
 * Copyright 2022 LiveKit
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
import WebRTC

@objc
public class VideoEncoding: NSObject, MediaEncoding {

    @objc
    public var maxBitrate: Int

    @objc
    public var maxFps: Int

    @objc
    public init(maxBitrate: Int, maxFps: Int) {
        self.maxBitrate = maxBitrate
        self.maxFps = maxFps
    }

    // MARK: - Equal

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return self.maxBitrate == other.maxBitrate &&
            self.maxFps == other.maxFps
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(maxBitrate)
        hasher.combine(maxFps)
        return hasher.finalize()
    }
}
