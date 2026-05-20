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

/// Cross-reference to a case in an external specification document.
///
/// Just a URL — encode the precise location with an anchor (e.g. GitHub's
/// `?plain=1#L<n>`) so it scrolls to the relevant line when clicked. Test
/// suites pass these directly to `@Test(...)`; the retroactive conformance
/// below makes `URL` itself a `TestTrait`. Pair with the `.spec` tag for
/// runtime filtering.
///
/// Usage:
/// ```swift
/// @Test(.tags(.spec), RpcSpec.V2V2.callerHappyShort)
/// func someTest() async throws { … }
/// ```
typealias SpecCase = URL

extension URL: @retroactive TestTrait, @retroactive SuiteTrait {}
