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
/// `Test.traits`. URL should be pinned to a specific upstream revision and
/// include a fragment anchor that scrolls to the case.
///
/// ```swift
/// @Test(.spec("https://example.com/specs/some-spec.md?plain=1#L42"))
/// func someTest() async throws { … }
/// ```
struct SpecCase: TestTrait, SuiteTrait {
    /// Source URL for the case (typically pinned to a commit and with a line anchor).
    let url: URL
}

extension Trait where Self == SpecCase {
    /// Cross-reference this test to a case in an external specification document.
    static func spec(_ url: URL) -> Self { SpecCase(url: url) }

    /// Convenience overload: parse a literal URL string. Force-unwrap is safe
    /// here because call sites pass constants verified at the next test build.
    static func spec(_ urlString: String) -> Self {
        SpecCase(url: URL(string: urlString)!)
    }
}
