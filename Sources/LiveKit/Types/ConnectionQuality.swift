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

@objc
public enum ConnectionQuality: Int {
    case unknown
    case poor
    case good
    case excellent
}

extension Livekit_ConnectionQuality {

    func toLKType() -> ConnectionQuality {
        switch self {
        case .poor: return .poor
        case .good: return .good
        case .excellent: return .excellent
        default: return .unknown
        }
    }
}
