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
@testable import LiveKit
import Testing

@Suite(.tags(.networking)) struct JoinRequestUrlTests {
    private static let url = URL(string: "wss://example.livekit.cloud")!

    private func joinRequestParam(reconnectMode: ReconnectMode? = nil) throws -> String {
        let url = try Utils.buildJoinRequestUrl(Self.url,
                                                connectOptions: ConnectOptions(),
                                                reconnectMode: reconnectMode,
                                                participantSid: nil,
                                                adaptiveStream: true)

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        // The percent-encoded query is what actually goes on the wire.
        let query = try #require(components.percentEncodedQuery)
        let param = try #require(query.split(separator: "&")
            .first { $0.hasPrefix("join_request=") }?
            .dropFirst("join_request=".count))
        return String(param)
    }

    /// `URLComponents` does not escape `+` or `/` in a query value, so standard
    /// base64 reaches the server intact only by luck — a receiver parsing the
    /// query as form-urlencoded turns `+` into a space.
    @Test func joinRequestParamIsUrlSafe() throws {
        let param = try joinRequestParam()

        #expect(!param.contains("+"), "Standard base64 leaked into the query: \(param)")
        #expect(!param.contains("/"), "Standard base64 leaked into the query: \(param)")
    }

    @Test(arguments: [nil, ReconnectMode.quick] as [ReconnectMode?])
    func joinRequestRoundTrips(reconnectMode: ReconnectMode?) throws {
        let param = try joinRequestParam(reconnectMode: reconnectMode)

        let decodedParam = try #require(param.removingPercentEncoding)
        let wrappedData = try #require(Data(base64URLEncoded: decodedParam))
        let wrapped = try Livekit_WrappedJoinRequest(serializedBytes: wrappedData)

        let joinRequestData: Data = switch wrapped.compression {
        case .gzip: try #require(Gunzip.decompress(wrapped.joinRequest))
        default: wrapped.joinRequest
        }

        let joinRequest = try Livekit_JoinRequest(serializedBytes: joinRequestData)
        #expect(joinRequest.clientInfo.sdk == .swift)
        #expect(joinRequest.clientInfo.version == LiveKitSDK.version)
        #expect(joinRequest.connectionSettings.adaptiveStream)
        #expect(joinRequest.reconnect == (reconnectMode == .quick))
    }

    /// A minimal join request is small enough that gzip framing outweighs the
    /// savings, so it must stay uncompressed rather than growing the URL.
    @Test func smallRequestIsNotCompressed() throws {
        let param = try joinRequestParam()

        let decodedParam = try #require(param.removingPercentEncoding)
        let wrappedData = try #require(Data(base64URLEncoded: decodedParam))
        let wrapped = try Livekit_WrappedJoinRequest(serializedBytes: wrappedData)

        #expect(wrapped.compression == .none)
    }
}

struct GzipTests {
    /// Known-answer vector for CRC-32 of "123456789".
    @Test func crc32MatchesKnownVector() throws {
        let data = try #require("123456789".data(using: .utf8))
        #expect(Gzip.crc32(data) == 0xCBF4_3926)
    }

    @Test func crc32OfEmptyDataIsZero() {
        #expect(Gzip.crc32(Data()) == 0)
    }

    @Test func compressProducesValidGzipStream() throws {
        // Repetitive enough that DEFLATE wins by a wide margin.
        let original = try #require(String(repeating: "livekit join request ", count: 200).data(using: .utf8))
        let compressed = try #require(Gzip.compress(original))

        #expect(compressed.count < original.count)
        #expect(Array(compressed.prefix(3)) == [0x1F, 0x8B, 0x08], "Missing gzip magic and DEFLATE method")

        let trailer = compressed.suffix(8)
        #expect(trailer.prefix(4).littleEndianUInt32 == Gzip.crc32(original))
        #expect(trailer.suffix(4).littleEndianUInt32 == UInt32(original.count))

        #expect(Gunzip.decompress(compressed) == original)
    }

    @Test func compressReturnsNilForEmptyData() {
        #expect(Gzip.compress(Data()) == nil)
    }

    /// Incompressible input may expand; the encoder must still emit a stream the
    /// caller can measure and reject, never a corrupt one.
    @Test func compressHandlesIncompressibleData() throws {
        var random = Data(count: 4096)
        random.withUnsafeMutableBytes { buffer in
            for index in buffer.indices {
                buffer[index] = UInt8.random(in: .min ... .max)
            }
        }

        let compressed = try #require(Gzip.compress(random))
        #expect(Gunzip.decompress(compressed) == random)
    }
}

// MARK: - Test helpers

/// Test-only gzip reader, used to prove the container the SDK writes is well
/// formed. The SDK itself only ever encodes.
private enum Gunzip {
    static func decompress(_ data: Data) -> Data? {
        // Fixed 10-byte header, 8-byte trailer; the SDK never emits optional fields.
        guard data.count > 18 else { return nil }
        let deflated = data.dropFirst(10).dropLast(8)
        guard let expectedSize = data.suffix(4).littleEndianUInt32 else { return nil }

        var result = Data(count: Int(expectedSize))
        let written = result.withUnsafeMutableBytes { destination -> Int in
            guard let destinationStart = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }

            return Data(deflated).withUnsafeBytes { source -> Int in
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

private extension Data {
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
