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

// Field accessors used by the generated facades: strings, bytes, scalars,
// enums, submessage views, oneof releases, and repeated fields. The core
// runtime (NanopbBox, NanopbMessage, wire-format primitives) is in Nanopb.swift.

// Single-module builds compile these sources into the product directly:
// CocoaPods surfaces the C declarations through the umbrella header, while the
// prebuilt xcframework resolves CLiveKitProto via its modulemap (package import
// so `package` declarations may expose C types without entering the public
// .swiftinterface).
#if LK_XCFRAMEWORK
package import CLiveKitProto
#elseif !COCOAPODS
import CLiveKitProto
#endif
import Foundation

// MARK: - Strings

package func lkString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    pointer.map { String(cString: $0) }
}

package func lkSetString(_ slot: inout UnsafeMutablePointer<CChar>?, _ value: String) {
    if let old = slot { free(old) }
    slot = strdup(value)
}

/// Borrow the bytes of an owned C string for the duration of `body` — no copy.
package func withLkBytes<R>(
    _ pointer: UnsafeMutablePointer<CChar>?,
    _ body: (UnsafeRawBufferPointer?) throws -> R,
) rethrows -> R {
    guard let pointer else { return try body(nil) }
    return try body(UnsafeRawBufferPointer(start: pointer, count: strlen(pointer)))
}

// MARK: - Bytes

package func lkData(_ pointer: UnsafeMutablePointer<pb_bytes_array_t>?) -> Data {
    guard let pointer, pointer.pointee.size > 0 else { return Data() }
    return withUnsafePointer(to: &pointer.pointee.bytes) {
        Data(bytes: UnsafeRawPointer($0), count: Int(pointer.pointee.size))
    }
}

package func lkSetData(_ slot: inout UnsafeMutablePointer<pb_bytes_array_t>?, _ value: Data) {
    if let old = slot { free(old) }
    slot = lkAllocBytes(value)
}

/// Borrow a bytes field without copying into `Data`.
package func withLkData<R>(
    _ pointer: UnsafeMutablePointer<pb_bytes_array_t>?,
    _ body: (UnsafeRawBufferPointer?) throws -> R,
) rethrows -> R {
    guard let pointer else { return try body(nil) }
    return try withUnsafePointer(to: &pointer.pointee.bytes) {
        try body(UnsafeRawBufferPointer(start: $0, count: Int(pointer.pointee.size)))
    }
}

func lkAllocBytes(_ value: Data) -> UnsafeMutablePointer<pb_bytes_array_t>? {
    // pb_bytes_array_t is a size header followed by an inline byte array.
    let header = MemoryLayout<pb_bytes_array_t>.offset(of: \pb_bytes_array_t.bytes) ?? 4
    guard let raw = malloc(header + max(value.count, 1)) else { return nil }
    let array = raw.bindMemory(to: pb_bytes_array_t.self, capacity: 1)
    array.pointee.size = pb_size_t(value.count)
    if !value.isEmpty {
        value.withUnsafeBytes { _ = memcpy(raw.advanced(by: header), $0.baseAddress!, value.count) }
    }
    return array
}

// MARK: - Scalars and enums

/// Scalar stored behind a pointer (proto3 `optional`).
package func lkSetValue<T>(_ slot: inout UnsafeMutablePointer<T>?, _ value: T) {
    if let old = slot { free(old) }
    guard let raw = malloc(MemoryLayout<T>.size) else { slot = nil; return }
    let pointer = raw.bindMemory(to: T.self, capacity: 1)
    pointer.initialize(to: value)
    slot = pointer
}

package func lkEnum<C: RawRepresentable, E: NanopbEnum>(_ value: C) -> E where C.RawValue == UInt32 {
    E(rawValue: Int(value.rawValue)) ?? E()
}

package func lkSetEnum<C: RawRepresentable>(
    _ slot: inout C, _ value: some NanopbEnum,
) where C.RawValue == UInt32 {
    if let converted = C(rawValue: UInt32(truncatingIfNeeded: value.rawValue)) {
        slot = converted
    }
}

package func lkSetEnumPointer<C: RawRepresentable>(
    _ slot: inout UnsafeMutablePointer<C>?, _ value: some NanopbEnum,
) where C.RawValue == UInt32 {
    guard let converted = C(rawValue: UInt32(truncatingIfNeeded: value.rawValue)) else { return }
    lkSetValue(&slot, converted)
}

// MARK: - Submessages

//
// nanopb nests a submessage inside (or pointed to from) its parent's
// allocation, while protobuf messages are independent values — so crossing that
// boundary copies, via an encode/decode round trip. Signalling messages are
// small; hot paths can use the zero-copy readers instead.

package func lkMessage<M: NanopbMessage>(_ pointer: UnsafeMutablePointer<M.Storage>?) -> M {
    guard let pointer else { return M() }
    return lkMessage(copying: pointer)
}

package func lkMessage<M: NanopbMessage>(copying pointer: UnsafePointer<M.Storage>) -> M {
    let message = M()
    do {
        let bytes = try nanopbEncodedBytes(pointer, M.descriptor)
        try bytes.withUnsafeBytes { try nanopbDecode(into: message._pointer, M.descriptor, $0) }
    } catch {
        // pb_decode releases whatever it allocated before failing, so the
        // result degrades to an empty message — reported, never silent.
        nanopbReportFailure("message copy", error)
    }
    return message
}

/// Address of a struct member inside a malloc'd allocation — the anchor for
/// zero-copy views into inline submessage fields.
package func lkMemberPointer<S, M>(
    _ base: UnsafeMutablePointer<S>, _ keyPath: WritableKeyPath<S, M>,
) -> UnsafeMutablePointer<M> {
    let offset = MemoryLayout<S>.offset(of: keyPath)!
    return (UnsafeMutableRawPointer(base) + offset).assumingMemoryBound(to: M.self)
}

/// Replace a pointer submessage field.
package func lkSetMessage<M: NanopbMessage>(
    _ slot: inout UnsafeMutablePointer<M.Storage>?, _ value: M,
) {
    lkRelease(message: &slot, M.descriptor)
    guard let raw = malloc(MemoryLayout<M.Storage>.size) else { return }
    let pointer = raw.bindMemory(to: M.Storage.self, capacity: 1)
    pointer.initialize(to: M.zero)
    lkOverwrite(pointer, with: value)
    slot = pointer
}

/// Replace an inline submessage field.
package func lkSetMessage<M: NanopbMessage>(inline slot: inout M.Storage, _ value: M) {
    var descriptor = M.descriptor
    withUnsafeMutablePointer(to: &slot) { lk_pb_release(&descriptor, UnsafeMutableRawPointer($0)) }
    slot = M.zero
    withUnsafeMutablePointer(to: &slot) { lkOverwrite($0, with: value) }
}

func lkOverwrite<M: NanopbMessage>(_ pointer: UnsafeMutablePointer<M.Storage>, with value: M) {
    do {
        let bytes = try nanopbEncodedBytes(value._pointer, M.descriptor)
        try bytes.withUnsafeBytes { try nanopbDecode(into: pointer, M.descriptor, $0) }
    } catch {
        // Encode failure leaves the destination untouched; a decode failure
        // degrades it to empty (pb_decode releases its partial allocations).
        nanopbReportFailure("message overwrite", error)
    }
}

// MARK: - Releasing oneof variants

//
// Union members share one address, so switching variants must release the old
// payload with the *old* variant's layout before the new one is written.

package func lkRelease(message slot: inout UnsafeMutablePointer<some Any>?, _ descriptor: pb_msgdesc_t) {
    guard let old = slot else { return }
    var descriptor = descriptor
    lk_pb_release(&descriptor, UnsafeMutableRawPointer(old))
    free(old)
    slot = nil
}

package func lkFree(_ slot: inout UnsafeMutablePointer<some Any>?) {
    if let old = slot { free(old) }
    slot = nil
}

// MARK: - Repeated fields

/// Borrow a repeated field for the duration of `body` — no array allocated.
package func withLkRepeated<C, R>(
    _ count: pb_size_t,
    _ base: UnsafeMutablePointer<C>?,
    _ body: (UnsafeBufferPointer<C>) throws -> R,
) rethrows -> R {
    guard let base, count > 0 else { return try body(.init(start: nil, count: 0)) }
    return try body(UnsafeBufferPointer(start: base, count: Int(count)))
}

package func lkRepeated<C>(_ count: pb_size_t, _ base: UnsafeMutablePointer<C>?) -> [C] {
    withLkRepeated(count, base) { Array($0) }
}

/// Repeated strings: an array of owned `char *`.
package func lkRepeated(
    _ count: pb_size_t, _ base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
) -> [String] {
    withLkRepeated(count, base) { $0.map { lkString($0) ?? "" } }
}

package func lkSetRepeated<C>(
    _ count: inout pb_size_t, _ base: inout UnsafeMutablePointer<C>?, _ values: [C],
) {
    if let old = base { free(old) }
    guard !values.isEmpty, let raw = malloc(MemoryLayout<C>.stride * values.count) else {
        base = nil
        count = 0
        return
    }
    let pointer = raw.bindMemory(to: C.self, capacity: values.count)
    for (index, value) in values.enumerated() {
        pointer.advanced(by: index).initialize(to: value)
    }
    base = pointer
    count = pb_size_t(values.count)
}

package func lkSetRepeated(
    _ count: inout pb_size_t,
    _ base: inout UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ values: [String],
) {
    // free the old strings themselves, not just the array of pointers
    withLkRepeated(count, base) { buffer in
        for pointer in buffer where pointer != nil {
            free(pointer)
        }
    }
    lkSetRepeated(&count, &base, values.map { strdup($0) })
}

package func lkRepeatedEnum<C: RawRepresentable, E: NanopbEnum>(
    _ count: pb_size_t, _ base: UnsafeMutablePointer<C>?,
) -> [E] where C.RawValue == UInt32 {
    withLkRepeated(count, base) { $0.map { E(rawValue: Int($0.rawValue)) ?? E() } }
}

package func lkSetRepeatedEnum<C: RawRepresentable>(
    _ count: inout pb_size_t, _ base: inout UnsafeMutablePointer<C>?, _ values: [some NanopbEnum],
) where C.RawValue == UInt32 {
    let converted = values.compactMap { C(rawValue: UInt32(truncatingIfNeeded: $0.rawValue)) }
    lkSetRepeated(&count, &base, converted)
}

package func lkRepeatedMessages<M: NanopbMessage>(
    _ count: pb_size_t, _ base: UnsafeMutablePointer<M.Storage>?,
) -> [M] {
    withLkRepeated(count, base) { buffer in
        buffer.indices.map { lkMessage(copying: buffer.baseAddress!.advanced(by: $0)) }
    }
}

package func lkSetRepeatedMessages<M: NanopbMessage>(
    _ count: inout pb_size_t, _ base: inout UnsafeMutablePointer<M.Storage>?, _ values: [M],
) {
    if let old = base {
        var descriptor = M.descriptor
        for index in 0 ..< Int(count) {
            lk_pb_release(&descriptor, UnsafeMutableRawPointer(old.advanced(by: index)))
        }
        free(old)
        base = nil
        count = 0
    }
    guard !values.isEmpty,
          let raw = malloc(MemoryLayout<M.Storage>.stride * values.count) else { return }
    let pointer = raw.bindMemory(to: M.Storage.self, capacity: values.count)
    for (index, value) in values.enumerated() {
        let slot = pointer.advanced(by: index)
        slot.initialize(to: M.zero)
        lkOverwrite(slot, with: value)
    }
    base = pointer
    count = pb_size_t(values.count)
}

package func lkCount(_ count: pb_size_t) -> Int { Int(count) }

/// Zero-copy views over a repeated submessage field. Each element retains
/// `owner`, so the parent's storage outlives every view handed out.
package func lkViews<M: NanopbMessage>(
    _ count: pb_size_t, _ base: UnsafeMutablePointer<M.Storage>?, owner: AnyObject,
) -> [M] {
    guard let base, count > 0 else { return [] }
    return (0 ..< Int(count)).map { M(_sharing: base + $0, owner: owner) }
}
