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

// nanopb's stream API, wrapped so the rest of the runtime never touches a
// `pb_ostream_t` directly. Typed throws carries the error type through the
// stdlib's untyped `rethrows`, which is why several of these capture a failure
// and re-throw it rather than letting it propagate out of the closure.

#if LK_XCFRAMEWORK
package import CLiveKitProto
#elseif !COCOAPODS
import CLiveKitProto
#endif
import Foundation

package func nanopbDecode(
    into pointer: UnsafeMutablePointer<some Any>,
    _ descriptor: pb_msgdesc_t,
    _ bytes: UnsafeRawBufferPointer,
) throws(NanopbError) {
    var descriptor = descriptor
    // SAFETY: nanopb reads at most `bytes.count` bytes from the buffer, and
    // the buffer outlives the call because the caller owns it for the
    // duration of `withUnsafeBytes`.
    var stream = lk_pb_istream_from_buffer(
        bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count,
    )
    guard lk_pb_decode(&stream, &descriptor, UnsafeMutableRawPointer(pointer)) else {
        throw NanopbError.decodeFailed(stream.errmsg.map { String(cString: $0) } ?? "unknown")
    }
}

package func nanopbEncodedSize(
    _ pointer: UnsafePointer<some Any>, _ descriptor: pb_msgdesc_t,
) throws(NanopbError) -> Int {
    var descriptor = descriptor
    var size = 0
    guard lk_pb_get_encoded_size(&size, &descriptor, UnsafeRawPointer(pointer)) else {
        throw NanopbError.encodeFailed("size")
    }
    return size
}

package func nanopbEncode(
    _ pointer: UnsafePointer<some Any>,
    _ descriptor: pb_msgdesc_t,
    into buffer: UnsafeMutableRawBufferPointer,
) throws(NanopbError) -> Int {
    var descriptor = descriptor
    // SAFETY: the stream is capped at `buffer.count`, so nanopb fails the
    // encode rather than overrunning if the size estimate was short.
    var stream = lk_pb_ostream_from_buffer(
        buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count,
    )
    guard lk_pb_encode(&stream, &descriptor, UnsafeRawPointer(pointer)) else {
        throw NanopbError.encodeFailed("encode")
    }
    return stream.bytes_written
}

package func nanopbEncodedBytes(
    _ pointer: UnsafePointer<some Any>, _ descriptor: pb_msgdesc_t,
) throws(NanopbError) -> [UInt8] {
    let size = try nanopbEncodedSize(pointer, descriptor)
    var out = [UInt8](repeating: 0, count: size)
    // `withUnsafeMutableBytes` is untyped `rethrows`, which would erase
    // NanopbError back to `any Error`; capture and rethrow to keep the type.
    var failure: NanopbError?
    var written = 0
    out.withUnsafeMutableBytes { buffer in
        do throws(NanopbError) {
            written = try nanopbEncode(pointer, descriptor, into: buffer)
        } catch {
            failure = error
        }
    }
    if let failure { throw failure }
    if written != size { out.removeLast(size - written) }
    return out
}

/// Same as `nanopbEncodedBytes`, but encodes straight into a `Data` for
/// callers that need one.
package func nanopbEncodedData(
    _ pointer: UnsafePointer<some Any>, _ descriptor: pb_msgdesc_t,
) throws(NanopbError) -> Data {
    let size = try nanopbEncodedSize(pointer, descriptor)
    var out = Data(count: size)
    var failure: NanopbError?
    var written = 0
    out.withUnsafeMutableBytes { buffer in
        do throws(NanopbError) {
            written = try nanopbEncode(pointer, descriptor, into: buffer)
        } catch {
            failure = error
        }
    }
    if let failure { throw failure }
    if written != size { out.removeLast(size - written) }
    return out
}
