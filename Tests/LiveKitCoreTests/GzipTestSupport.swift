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

import Compression
import Foundation

/// Test-only gzip reader, used to prove the container the SDK writes is well formed and to
/// read back `join_request` parameters. The SDK itself only ever encodes.
enum TestGunzip {
    static func decompress(_ data: Data) -> Data? {
        // Fixed 10-byte header, 8-byte trailer; the SDK never emits optional fields.
        guard data.count > 18 else { return nil }
        let deflated = Data(data.dropFirst(10).dropLast(8))
        guard let expectedSize = data.suffix(4).littleEndianUInt32 else { return nil }

        var result = Data(count: Int(expectedSize))
        let written = result.withUnsafeMutableBytes { destination -> Int in
            guard let destinationStart = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }

            return deflated.withUnsafeBytes { source -> Int in
                guard let sourceStart = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }

                return compression_decode_buffer(destinationStart, Int(expectedSize),
                                                 sourceStart, deflated.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }

        guard written == Int(expectedSize) else { return nil }
        return result
    }
}

extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Restore any stripped padding so Foundation accepts the string.
        if base64.count % 4 != 0 {
            base64 += String(repeating: "=", count: 4 - base64.count % 4)
        }
        self.init(base64Encoded: base64)
    }

    var littleEndianUInt32: UInt32? {
        guard count == 4 else { return nil }
        // `enumerated()` offsets are slice-relative, unlike `indices`.
        return enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }
}
