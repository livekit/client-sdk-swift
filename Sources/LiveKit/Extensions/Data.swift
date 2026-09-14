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

extension Data {
    /// Base64 using the URL-safe alphabet from
    /// [RFC 4648 §5](https://datatracker.ietf.org/doc/html/rfc4648#section-5).
    ///
    /// Required for values carried in a query string: `URLComponents` leaves
    /// `+` and `/` unescaped in a query value, and a receiver that parses the
    /// query as form-urlencoded decodes `+` as a space — silently corrupting
    /// standard base64. Padding is kept, matching client-sdk-js and rust-sdks.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}
