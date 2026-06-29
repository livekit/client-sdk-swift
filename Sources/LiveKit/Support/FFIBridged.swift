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

/// Internal marker for a public type that wraps a `LiveKitUniFFI` value.
///
/// Conforming types are thin bridges over the UniFFI layer: ``FFIType`` is the wrapped value and
/// ``init(_:)`` lifts it into the public type. The protocol is internal — it documents the bridge
/// boundary, it is not part of the public API.
protocol FFIBridged {
    /// The wrapped `LiveKitUniFFI` type.
    associatedtype FFIType

    /// Wraps the underlying FFI value.
    init(_ ffi: FFIType)
}
