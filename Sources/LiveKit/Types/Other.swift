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
import Promises

public typealias Sid = String

// A tuple of Promises.
// listen: resolves when started listening
// wait: resolves when wait is complete or rejects when timeout
internal typealias WaitPromises<T> = (listen: Promise<Void>, wait: () -> Promise<T>)

@objc
public enum Reliability: Int {
    case reliable
    case lossy
}

internal extension Reliability {

    func toPBType() -> Livekit_DataPacket.Kind {
        if self == .lossy { return .lossy }
        return .reliable
    }
}

public enum SimulateScenario {
    case nodeFailure
    case migration
    case serverLeave
    case speakerUpdate(seconds: Int)
}
