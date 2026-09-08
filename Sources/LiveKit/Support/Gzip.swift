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

/// Minimal gzip ([RFC 1952](https://datatracker.ietf.org/doc/html/rfc1952)) encoder.
///
/// Apple's Compression framework has no gzip container: `COMPRESSION_ZLIB`
/// produces a raw DEFLATE stream ([RFC 1951](https://datatracker.ietf.org/doc/html/rfc1951))
/// with no header, checksum or length trailer. This wraps that stream in the
/// gzip framing the LiveKit server expects, rather than linking zlib just for
/// its container.
enum Gzip {
    /// Fixed 10-byte gzip header: magic, DEFLATE method, no flags, no mtime,
    /// no extra flags, unknown OS. The mtime is left zero so the same input
    /// always encodes to the same bytes and no clock value is disclosed.
    private static let header: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF]

    /// Compresses `data` into a gzip stream.
    ///
    /// - Returns: The gzip stream, or `nil` when `data` is empty or DEFLATE
    ///   fails. Callers are expected to fall back to the uncompressed payload.
    /// - Note: DEFLATE can expand incompressible input, so the result is not
    ///   guaranteed to be smaller than `data`. Compare the sizes before use.
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        // Worst-case DEFLATE expansion plus room for the block headers.
        let capacity = data.count + data.count / 16 + 64
        var deflated = Data(count: capacity)

        let deflatedCount = deflated.withUnsafeMutableBytes { destination -> Int in
            guard let destinationStart = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }

            return data.withUnsafeBytes { source -> Int in
                guard let sourceStart = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }

                return compression_encode_buffer(destinationStart, capacity,
                                                 sourceStart, data.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }

        // `compression_encode_buffer` reports failure as zero bytes written.
        guard deflatedCount > 0 else { return nil }

        var result = Data(header)
        result.append(deflated.prefix(deflatedCount))
        result.append(littleEndian: crc32(data))
        // ISIZE is the uncompressed size modulo 2^32.
        result.append(littleEndian: UInt32(truncatingIfNeeded: data.count))
        return result
    }

    /// CRC-32 as specified by gzip: reflected polynomial `0xEDB88320`,
    /// pre-inverted and post-inverted.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { index in
        (0 ..< 8).reduce(UInt32(index)) { value, _ in
            (value & 1) != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        var value = value.littleEndian
        append(contentsOf: Swift.withUnsafeBytes(of: &value) { Array($0) })
    }
}
