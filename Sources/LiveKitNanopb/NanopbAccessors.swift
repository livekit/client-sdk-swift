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
    // SAFETY: `slot` is owned by one box, and a message is only mutated
    // through its own `Builder`, so no other value can observe the old
    // pointer between the free and the store.
    if let old = slot { free(old) }
    slot = strdup(value)
}

/// Borrow the bytes of an owned C string for the duration of `body` — no copy.
package func withLkBytes<R, E: Error>(
    _ pointer: UnsafeMutablePointer<CChar>?,
    _ body: (UnsafeRawBufferPointer?) throws(E) -> R,
) throws(E) -> R {
    guard let pointer else { return try body(nil) }
    return try body(UnsafeRawBufferPointer(start: pointer, count: strlen(pointer)))
}

// MARK: - Bytes

/// `pb_bytes_array_t` is a size header followed by an inline byte array; the
/// payload starts at that member's offset.
private let lkBytesHeader = MemoryLayout<pb_bytes_array_t>.offset(of: \pb_bytes_array_t.bytes) ?? 4

private func lkBytesBase(_ pointer: UnsafeMutablePointer<pb_bytes_array_t>) -> UnsafeRawPointer {
    // SAFETY: `pointer` comes from `lkAllocBytes`, which allocates
    // `lkBytesHeader + size` bytes, so the payload is in bounds for `size`
    // bytes. Reading `bytes` as a Swift tuple would only cover one element.
    UnsafeRawPointer(pointer).advanced(by: lkBytesHeader)
}

package func lkData(_ pointer: UnsafeMutablePointer<pb_bytes_array_t>?) -> Data {
    guard let pointer, pointer.pointee.size > 0 else { return Data() }
    return Data(bytes: lkBytesBase(pointer), count: Int(pointer.pointee.size))
}

package func lkSetData(_ slot: inout UnsafeMutablePointer<pb_bytes_array_t>?, _ value: Data) {
    if let old = slot { free(old) }
    slot = lkAllocBytes(value)
}

/// Borrow a bytes field without copying into `Data`.
package func withLkData<R, E: Error>(
    _ pointer: UnsafeMutablePointer<pb_bytes_array_t>?,
    _ body: (UnsafeRawBufferPointer?) throws(E) -> R,
) throws(E) -> R {
    guard let pointer else { return try body(nil) }
    return try body(UnsafeRawBufferPointer(start: lkBytesBase(pointer),
                                           count: Int(pointer.pointee.size)))
}

func lkAllocBytes(_ value: Data) -> UnsafeMutablePointer<pb_bytes_array_t>? {
    let header = lkBytesHeader
    // SAFETY: at least one byte is always allocated so the flexible array
    // member has a valid address even for an empty payload; the memcpy below
    // is bounded by the same `value.count` used to size the allocation.
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
    guard let pointer else { return M._empty }
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
    // SAFETY: `S` is a C struct imported with its C layout, so the member
    // offset is stable and the result stays inside `base`'s allocation.
    let offset = MemoryLayout<S>.offset(of: keyPath)!
    return (UnsafeMutableRawPointer(base) + offset).assumingMemoryBound(to: M.self)
}

/// Replace a pointer submessage field.
package func lkSetMessage<M: NanopbMessage>(
    _ slot: inout UnsafeMutablePointer<M.Storage>?, _ value: M,
) {
    // SAFETY: as in `lkSetRepeatedMessages`, `value` may be a view into the
    // storage this replaces, so it is copied before the old slot is released.
    guard let raw = malloc(MemoryLayout<M.Storage>.size) else { return }
    let pointer = raw.bindMemory(to: M.Storage.self, capacity: 1)
    pointer.initialize(to: M.zero)
    lkOverwrite(pointer, with: value)
    lkRelease(message: &slot, M.descriptor)
    slot = pointer
}

/// Replace an inline submessage field.
package func lkSetMessage<M: NanopbMessage>(inline slot: inout M.Storage, _ value: M) {
    // SAFETY: `value` may be a view into `slot`, so serialise it before the
    // release; the bytes are independent of the storage being freed.
    let encoded = try? nanopbEncodedBytes(value._pointer, M.descriptor)
    var descriptor = M.descriptor
    withUnsafeMutablePointer(to: &slot) { lk_pb_release(&descriptor, UnsafeMutableRawPointer($0)) }
    slot = M.zero
    guard let encoded else { return }

    var failure: NanopbError?
    withUnsafeMutablePointer(to: &slot) { destination in
        encoded.withUnsafeBytes { buffer in
            do throws(NanopbError) {
                try nanopbDecode(into: destination, M.descriptor, buffer)
            } catch {
                failure = error
            }
        }
    }
    if let failure { nanopbReportFailure("message overwrite", failure) }
}

package func lkOverwrite<M: NanopbMessage>(_ pointer: UnsafeMutablePointer<M.Storage>, with value: M) {
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
package func withLkRepeated<C, R, E: Error>(
    _ count: pb_size_t,
    _ base: UnsafeMutablePointer<C>?,
    _ body: (UnsafeBufferPointer<C>) throws(E) -> R,
) throws(E) -> R {
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
    // SAFETY: `values` may alias the array being replaced — the getter hands
    // out views into it, so `field.append(x)` reads views and assigns them
    // straight back. Copy into fresh storage *first*; releasing the old array
    // up front would free the bytes those views are read from.
    var fresh: UnsafeMutablePointer<M.Storage>?
    if !values.isEmpty, let raw = malloc(MemoryLayout<M.Storage>.stride * values.count) {
        let pointer = raw.bindMemory(to: M.Storage.self, capacity: values.count)
        for (index, value) in values.enumerated() {
            let slot = pointer.advanced(by: index)
            slot.initialize(to: M.zero)
            lkOverwrite(slot, with: value)
        }
        fresh = pointer
    }
    // SAFETY: each element owns nested allocations, so every one must be
    // released with its descriptor before the array itself is freed —
    // freeing the array alone would leak the whole subtree.
    if let old = base {
        var descriptor = M.descriptor
        for index in 0 ..< Int(count) {
            lk_pb_release(&descriptor, UnsafeMutableRawPointer(old.advanced(by: index)))
        }
        free(old)
    }
    base = fresh
    count = fresh == nil ? 0 : pb_size_t(values.count)
}

package func lkCount(_ count: pb_size_t) -> Int { Int(count) }

/// Zero-copy views over a repeated submessage field. Each element retains
/// `owner`, so the parent's storage outlives every view handed out.
package func lkViews<M: NanopbMessage>(
    _ count: pb_size_t, _ base: UnsafeMutablePointer<M.Storage>?, owner: NanopbAnyBox,
) -> [M] {
    // SAFETY: every element retains `owner`, so the parent's allocation
    // outlives each view; storage is immutable once published, so the
    // elements can be read while other values share the same box.
    guard let base, count > 0 else { return [] }
    return (0 ..< Int(count)).map { M(_sharing: base + $0, owner: owner) }
}

// MARK: - Spans

#if compiler(>=6.2)
// `Span` and `RawSpan` are Swift 6.2 stdlib types that back-deploy to
// macOS 10.14.4 / iOS 12.2, so only the compiler floor gates them, not the
// deployment target. They give the closure body a bounds-checked view instead
// of a raw pointer; returning one would additionally need a lifetime
// annotation (`@_lifetime`), which is still experimental, so the borrow stays
// scoped to the call.

/// Borrow a bytes field as a bounds-checked `RawSpan`.
package func withLkSpan<R, E: Error>(
    _ pointer: UnsafeMutablePointer<pb_bytes_array_t>?,
    _ body: (RawSpan) throws(E) -> R,
) throws(E) -> R {
    try withLkData(pointer) { (buffer: UnsafeRawBufferPointer?) throws(E) -> R in
        try body(unsafe RawSpan(_unsafeBytes: buffer ?? UnsafeRawBufferPointer(start: nil, count: 0)))
    }
}

/// Borrow a repeated scalar field as a bounds-checked `Span`.
package func withLkSpan<C: BitwiseCopyable, R, E: Error>(
    _ count: pb_size_t,
    _ base: UnsafeMutablePointer<C>?,
    _ body: (Span<C>) throws(E) -> R,
) throws(E) -> R {
    try withLkRepeated(count, base) { (buffer: UnsafeBufferPointer<C>) throws(E) -> R in
        try body(unsafe Span(_unsafeElements: buffer))
    }
}
#endif
