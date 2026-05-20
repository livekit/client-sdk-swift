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

/// Cross-reference to a required test case in an external specification document.
///
/// Swift Testing has no built-in renderer for custom-trait payloads, so this trait
/// is pure metadata: it records which test pins which spec case and where the spec
/// lives. Source review and any future coverage-mapping tooling that walks
/// `Test.traits` can resolve the URL back to the canonical case. For runtime
/// filtering, pair with the `.spec` tag.
///
/// Usage:
/// ```swift
/// @Test(.tags(.spec), .spec("v2-v2-#1", "Caller happy (short)", url: someSpecURL))
/// func someTest() async throws { … }
/// ```
struct SpecCase: TestTrait, SuiteTrait {
    /// Stable case identifier within the spec — e.g. `"v2-v2-#1"`.
    let id: String
    /// Short human-readable title, mirroring the spec section heading.
    let title: String
    /// Source URL for the spec document (anchor optional).
    let url: URL
}

extension Trait where Self == SpecCase {
    /// Reference a required case in an external specification document.
    static func spec(_ id: String, _ title: String, url: URL) -> Self {
        SpecCase(id: id, title: title, url: url)
    }
}
