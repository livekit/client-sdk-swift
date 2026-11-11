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

extension FakeWebSocketServer {
    /// A server frame with an unmasked payload and the shortest length encoding.
    static func frame(_ opcode: UInt8, _ payload: Data, final: Bool = true) -> Data {
        let length: [UInt8] = switch payload.count {
        case ..<126:
            [UInt8(payload.count)]
        case ...0xFFFF:
            [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default:
            [127] + (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) }
        }
        let fin: UInt8 = final ? 0x80 : 0
        return Data([fin | opcode] + length) + payload
    }

    /// Binary messages, one per payload.
    static func binary(_ payloads: [Data]) -> Data {
        payloads.reduce(into: Data()) { $0 += frame(0x2, $1) }
    }

    static func close(_ code: UInt16, reason: String = "") -> Data {
        frame(0x8, Data([UInt8(code >> 8), UInt8(code & 0xFF)]) + Data(reason.utf8))
    }
}
