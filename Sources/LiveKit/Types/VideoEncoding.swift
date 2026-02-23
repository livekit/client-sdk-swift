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

@objcMembers
public final class VideoEncoding: NSObject, MediaEncoding, Sendable {
    public let maxBitrate: Int

    public let maxFps: Int

    /// Priority for bandwidth allocation.
    public let bitratePriority: Priority?

    /// Priority for DSCP marking.
    /// Requires `ConnectOptions.isDscpEnabled` to be true.
    public let networkPriority: Priority?

    public init(maxBitrate: Int, maxFps: Int) {
        self.maxBitrate = maxBitrate
        self.maxFps = maxFps
        bitratePriority = nil
        networkPriority = nil
    }

    public init(maxBitrate: Int, maxFps: Int, bitratePriority: Priority?, networkPriority: Priority?) {
        self.maxBitrate = maxBitrate
        self.maxFps = maxFps
        self.bitratePriority = bitratePriority
        self.networkPriority = networkPriority
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return maxBitrate == other.maxBitrate &&
            maxFps == other.maxFps &&
            bitratePriority == other.bitratePriority &&
            networkPriority == other.networkPriority
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(maxBitrate)
        hasher.combine(maxFps)
        hasher.combine(bitratePriority)
        hasher.combine(networkPriority)
        return hasher.finalize()
    }
}
