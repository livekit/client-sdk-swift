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

public enum ProtocolVersion {
    case v2
    case v3
    case v4
    case v5
    case v6
    case v7
    case v8
}

extension ProtocolVersion: CustomStringConvertible {

    public var description: String {
        switch self {
        case .v2: return "2"
        case .v3: return "3"
        case .v4: return "4"
        case .v5: return "5"
        case .v6: return "6"
        case .v7: return "7"
        case .v8: return "8"
        }
    }
}
