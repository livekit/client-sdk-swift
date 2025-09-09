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

protocol StreamData: Sendable {
    func chunks(of size: Int) -> [Data]
}

extension Data: StreamData {
    func chunks(of size: Int) -> [Data] {
        guard size > 0, !isEmpty else { return [] }
        return stride(from: startIndex, to: endIndex, by: size).map {
            let end = index($0, offsetBy: size, limitedBy: endIndex) ?? endIndex
            return self[$0 ..< end]
        }
    }
}

extension String: StreamData {
    /// Chunk along valid UTF-8 bounderies.
    ///
    /// Uses the same algorithm as in the LiveKit JS SDK.
    ///
    func chunks(of size: Int) -> [Data] {
        guard size > 0, !isEmpty else { return [] }

        var chunks: [Data] = []
        var encoded = Data(utf8)[...]

        while encoded.count > size {
            var k = size
            while k > 0 {
                guard encoded.indices.contains(k),
                      encoded[k] & 0xC0 == 0x80 else { break }
                k -= 1
            }
            chunks.append(encoded.subdata(in: 0 ..< k))
            encoded = encoded.subdata(in: k ..< encoded.count)
        }
        if !encoded.isEmpty {
            chunks.append(encoded)
        }
        return chunks
    }
}
