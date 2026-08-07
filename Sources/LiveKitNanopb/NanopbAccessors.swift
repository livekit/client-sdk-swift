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
// boundary copies, via an encode/decode round trip. Reading a submessage does
// not: the getter hands out a view. Signalling messages are small either way.

package func lkMessage<S: NanopbStorage>(_ pointer: UnsafeMutablePointer<S>?) -> NanopbMsg<S> {
    guard let pointer else { return NanopbMsg<S>._empty }
    return lkMessage(copying: pointer)
}

package func lkMessage<S: NanopbStorage>(copying pointer: UnsafePointer<S>) -> NanopbMsg<S> {
    let message = NanopbMsg<S>()
    do {
        let bytes = try nanopbEncodedBytes(pointer, S.descriptor)
        try bytes.withUnsafeBytes { try nanopbDecode(into: message._pointer, S.descriptor, $0) }
    } catch {
        // pb_decode releases whatever it allocated before failing, so the
        // result degrades to an empty message — reported, never silent.
        nanopbReportFailure("message copy", error)
    }
    return message
}

/// Replace a pointer submessage field.
package func lkSetMessage<S: NanopbStorage>(
    _ slot: inout UnsafeMutablePointer<S>?, _ value: NanopbMsg<S>,
) {
    // SAFETY: as in `lkSetRepeatedMessages`, `value` may be a view into the
    // storage this replaces, so it is copied before the old slot is released.
    guard let raw = malloc(MemoryLayout<S>.size) else { return }
    let pointer = raw.bindMemory(to: S.self, capacity: 1)
    pointer.initialize(to: S())
    lkOverwrite(pointer, with: value)
    lkRelease(message: &slot, S.descriptor)
    slot = pointer
}

/// Replace an inline submessage field.
package func lkSetMessage<S: NanopbStorage>(inline slot: inout S, _ value: NanopbMsg<S>) {
    // SAFETY: `value` may be a view into `slot`, so serialise it before the
    // release; the bytes are independent of the storage being freed.
    let encoded = try? nanopbEncodedBytes(value._pointer, S.descriptor)
    var descriptor = S.descriptor
    withUnsafeMutablePointer(to: &slot) { lk_pb_release(&descriptor, UnsafeMutableRawPointer($0)) }
    slot = S()
    guard let encoded else { return }

    var failure: NanopbError?
    withUnsafeMutablePointer(to: &slot) { destination in
        encoded.withUnsafeBytes { buffer in
            do throws(NanopbError) {
                try nanopbDecode(into: destination, S.descriptor, buffer)
            } catch {
                failure = error
            }
        }
    }
    if let failure { nanopbReportFailure("message overwrite", failure) }
}

package func lkOverwrite<S: NanopbStorage>(_ pointer: UnsafeMutablePointer<S>, with value: NanopbMsg<S>) {
    do {
        let bytes = try nanopbEncodedBytes(value._pointer, S.descriptor)
        try bytes.withUnsafeBytes { try nanopbDecode(into: pointer, S.descriptor, $0) }
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

package func lkSetRepeatedMessages<S: NanopbStorage>(
    _ count: inout pb_size_t, _ base: inout UnsafeMutablePointer<S>?, _ values: [NanopbMsg<S>],
) {
    // SAFETY: `values` may alias the array being replaced — the getter hands
    // out views into it, so `field.append(x)` reads views and assigns them
    // straight back. Copy into fresh storage *first*; releasing the old array
    // up front would free the bytes those views are read from.
    var fresh: UnsafeMutablePointer<S>?
    if !values.isEmpty, let raw = malloc(MemoryLayout<S>.stride * values.count) {
        let pointer = raw.bindMemory(to: S.self, capacity: values.count)
        for (index, value) in values.enumerated() {
            let slot = pointer.advanced(by: index)
            slot.initialize(to: S())
            lkOverwrite(slot, with: value)
        }
        fresh = pointer
    }
    // SAFETY: each element owns nested allocations, so every one must be
    // released with its descriptor before the array itself is freed —
    // freeing the array alone would leak the whole subtree.
    if let old = base {
        var descriptor = S.descriptor
        for index in 0 ..< Int(count) {
            lk_pb_release(&descriptor, UnsafeMutableRawPointer(old.advanced(by: index)))
        }
        free(old)
    }
    base = fresh
    count = fresh == nil ? 0 : pb_size_t(values.count)
}

/// Zero-copy views over a repeated submessage field. Each element retains
/// `owner`, so the parent's storage outlives every view handed out.
package func lkViews<S: NanopbStorage>(
    _ count: pb_size_t, _ base: UnsafeMutablePointer<S>?, owner: NanopbAnyBox,
) -> [NanopbMsg<S>] {
    // SAFETY: every element retains `owner`, so the parent's allocation
    // outlives each view; storage is immutable once published, so the
    // elements can be read while other values share the same box.
    guard let base, count > 0 else { return [] }
    return (0 ..< Int(count)).map { NanopbMsg<S>(_sharing: base + $0, owner: owner) }
}

// MARK: - Borrowing primitives (currently unused)

//
// Nothing borrows a scalar field today: submessage and repeated-submessage
// reads are already zero-copy views, and everything else copies out at the
// API boundary anyway. Two shapes were built and removed once measured to be
// dead — re-add them here if a hot path ever needs one:
//
//   - `withLkData(_:_:)` / `withLkBytes(_:_:)`, closure-scoped borrows handing
//     the body an `UnsafeRawBufferPointer` into nanopb's allocation.
//   - `withLkSpan(_:_:)` behind `#if compiler(>=6.2)`, the same borrow but
//     bounds-checked; `Span`/`RawSpan` back-deploy to iOS 12.2, so only the
//     compiler floor gates them. Returning a span rather than scoping it to
//     the call additionally needs `@_lifetime`, still experimental.
