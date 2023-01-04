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
public class ScreenShareCaptureOptions: NSObject, VideoCaptureOptions {

    @objc
    public let dimensions: Dimensions

    @objc
    public let fps: Int

    /// Only used for macOS
    @objc
    public let showCursor: Bool

    @objc
    public let useBroadcastExtension: Bool

    public init(dimensions: Dimensions = .h1080_169,
                fps: Int = 15,
                showCursor: Bool = true,
                useBroadcastExtension: Bool = false) {
        self.dimensions = dimensions
        self.fps = fps
        self.showCursor = showCursor
        self.useBroadcastExtension = useBroadcastExtension
    }

    // MARK: - Equal

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return self.dimensions == other.dimensions &&
            self.fps == other.fps &&
            self.showCursor == other.showCursor &&
            self.useBroadcastExtension == other.useBroadcastExtension
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(dimensions)
        hasher.combine(fps)
        hasher.combine(showCursor)
        hasher.combine(useBroadcastExtension)
        return hasher.finalize()
    }
}
