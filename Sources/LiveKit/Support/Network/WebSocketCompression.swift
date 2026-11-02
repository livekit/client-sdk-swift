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

internal import zlib
import Foundation

/// RFC 7692 parameters. Each connection owns a separate inflater and deflater, under the inbox and write locks.
struct WebSocketCompression: Sendable {
    var serverWindowBits = 15
    var clientWindowBits = 15
    var serverNoContextTakeover = false
    var clientNoContextTakeover = false

    static func negotiate(_ headers: [String]) throws -> Self? {
        guard !headers.isEmpty else { return nil }
        guard headers.count == 1 else { throw failure() }
        let parts = headers[0].split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.first == "permessage-deflate" else { throw failure() }
        var result = Self()
        var seen: Set<String> = []
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = pair.first, seen.insert(name).inserted else { throw failure() }
            try result.apply(name: name, value: pair.count == 2 ? pair.last : nil)
        }
        return result
    }

    private mutating func apply(name: String, value: String?) throws {
        switch name {
        case "server_no_context_takeover", "client_no_context_takeover":
            guard value == nil else { throw Self.failure() }
            if name == "server_no_context_takeover" {
                serverNoContextTakeover = true
            } else {
                clientNoContextTakeover = true
            }
        case "server_max_window_bits", "client_max_window_bits":
            guard let value else { throw Self.failure() }
            let unquoted = value.hasPrefix("\"") && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : value
            guard let bits = Int(unquoted), (8 ... 15).contains(bits), String(bits) == unquoted else { throw Self.failure() }
            if name == "server_max_window_bits" {
                serverWindowBits = bits
            } else {
                clientWindowBits = bits
            }
        default:
            throw Self.failure()
        }
    }

    static func failure(_ code: Int32 = EPROTO) -> LiveKitError {
        LiveKitError(.network, message: "WebSocket compression failed", internalError: NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
    }

    /// A raw zlib stream, accessed only under its owner's existing StateSync lock. It is deliberately not Sendable.
    final class Codec {
        /// zlib retains the stream's address internally; a Swift value passed with `&` does not promise a stable address.
        private final class Storage {
            let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
            init() { stream.initialize(to: z_stream()) }
            deinit {
                stream.deinitialize(count: 1)
                stream.deallocate()
            }
        }

        private let storage = Storage()
        private let compressing: Bool
        private let noContextTakeover: Bool
        private var initialized = false
        private static let trailer = Data([0, 0, 255, 255])

        init(compressing: Bool, windowBits: Int, noContextTakeover: Bool) throws {
            self.compressing = compressing
            self.noContextTakeover = noContextTakeover
            let status: Int32 = if compressing {
                // zlib cannot deflate with an 8-bit window. Huffman-only emits no distances, so a 9-bit
                // implementation still produces a stream valid for an 8-bit peer.
                deflateInit2_(storage.stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -Int32(max(9, windowBits)), 8,
                              windowBits == 8 ? Z_HUFFMAN_ONLY : Z_DEFAULT_STRATEGY,
                              ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            } else {
                // A peer can use a larger window than it advertises. A 15-bit inflater accepts every window size.
                inflateInit2_(storage.stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            }
            guard status == Z_OK else { throw WebSocketCompression.failure(status == Z_MEM_ERROR ? ENOMEM : EPROTO) }
            initialized = true
        }

        deinit {
            guard initialized else { return }
            if compressing { deflateEnd(storage.stream) } else { inflateEnd(storage.stream) }
        }

        /// Processes even partial frame payloads. The limit is checked before appending each output chunk.
        func process(_ input: Data, final: Bool, maximumOutputSize: Int = Int.max) throws -> Data {
            var input = input
            if !compressing, final { input.append(Self.trailer) }
            let stream = storage.stream
            var output = Data()
            try input.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                defer {
                    stream.pointee.next_in = nil
                    stream.pointee.next_out = nil
                }
                var offset = 0
                repeat {
                    let count = min(input.count - offset, 1 << 16)
                    stream.pointee.next_in = bytes.baseAddress.map { UnsafeMutablePointer(mutating: $0.advanced(by: offset)) }
                    stream.pointee.avail_in = uInt(count)
                    let flush = final && offset + count == input.count ? Z_SYNC_FLUSH : Z_NO_FLUSH
                    try pump(flush: flush, maximumOutputSize: maximumOutputSize, output: &output)
                    offset += count
                } while offset < input.count
            }
            if !compressing, final, stream.pointee.data_type & 128 == 0 { throw WebSocketCompression.failure() }
            if compressing, final {
                // A repeated empty SYNC_FLUSH can produce nothing. RFC 7692 §7.2.3.6 permits this empty block.
                if output.isEmpty, input.isEmpty { output = Data([0]) + Self.trailer }
                guard output.suffix(4) == Self.trailer else { throw WebSocketCompression.failure() }
                output.removeLast(4)
            }
            if final, noContextTakeover {
                let status = compressing ? deflateReset(stream) : inflateReset(stream)
                guard status == Z_OK else { throw WebSocketCompression.failure() }
            }
            return output
        }

        private func pump(flush: Int32, maximumOutputSize: Int, output: inout Data) throws {
            let stream = storage.stream
            var buffer = [UInt8](repeating: 0, count: 8192)
            repeat {
                let before = stream.pointee.avail_in
                let status = buffer.withUnsafeMutableBufferPointer { buffer in
                    stream.pointee.next_out = buffer.baseAddress
                    stream.pointee.avail_out = uInt(buffer.count)
                    return compressing ? deflate(stream, flush) : inflate(stream, Z_BLOCK)
                }
                let produced = buffer.count - Int(stream.pointee.avail_out)
                guard produced <= maximumOutputSize - output.count else { throw WebSocketCompression.failure(EMSGSIZE) }
                output.append(contentsOf: buffer.prefix(produced))
                if !compressing, status == Z_STREAM_END {
                    try restartInflater()
                    continue
                }
                guard status == Z_OK || (status == Z_BUF_ERROR && stream.pointee.avail_in == 0) else {
                    throw WebSocketCompression.failure()
                }
                if before == stream.pointee.avail_in, produced == 0 {
                    guard stream.pointee.avail_in == 0 else { throw WebSocketCompression.failure() }
                    break
                }
            } while stream.pointee.avail_in > 0 || stream.pointee.avail_out == 0
        }

        /// RFC 7692 §7.2.3.4 allows BFINAL blocks followed by another DEFLATE stream. Keep the negotiated history.
        private func restartInflater() throws {
            var dictionary = [UInt8](repeating: 0, count: 1 << 15)
            var count: uInt = 0
            let status = dictionary.withUnsafeMutableBufferPointer { inflateGetDictionary(storage.stream, $0.baseAddress, &count) }
            guard status == Z_OK, inflateReset(storage.stream) == Z_OK else { throw WebSocketCompression.failure() }
            if count > 0 {
                let status = dictionary.withUnsafeBufferPointer { inflateSetDictionary(storage.stream, $0.baseAddress, count) }
                guard status == Z_OK else { throw WebSocketCompression.failure() }
            }
        }
    }
}
