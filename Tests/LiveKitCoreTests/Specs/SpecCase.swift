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

import Foundation
import Testing

/// Cross-references a test to a case in an external specification document.
///
/// Pure metadata: Swift Testing has no built-in renderer for custom-trait
/// payloads, so the trait simply records the URL where the case lives for
/// source review and any future coverage-mapping tooling that walks
/// `Test.traits`. Spec namespaces live next to this file (e.g. `URL.rpc.*`
/// in `RpcSpec.swift`) so a leading dot resolves them through `.spec(...)`:
///
/// ```swift
/// @Test(.spec(.rpc.V2V2.callerHappyPathShort))
/// func v2CallerHappyPathShort() async throws { … }
/// ```
struct SpecCase: TestTrait, SuiteTrait {
    /// Source URL for the case (typically pinned to a commit and with a line anchor).
    let url: URL
}

extension Trait where Self == SpecCase {
    /// Cross-reference this test to a case in an external specification document.
    static func spec(_ url: URL) -> Self { SpecCase(url: url) }
}
