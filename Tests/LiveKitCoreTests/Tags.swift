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

import Testing

extension Tag {
    /// Audio engine, processing, recording, and buffer tests.
    @Tag static var audio: Self
    /// Screen broadcast and sharing tests.
    @Tag static var broadcast: Self
    /// Async primitives and thread safety tests.
    @Tag static var concurrency: Self
    /// WebRTC data channel tests.
    @Tag static var dataChannel: Self
    /// Text and byte data stream tests.
    @Tag static var dataStream: Self
    /// Data track publish/subscribe tests.
    @Tag static var dataTrack: Self
    /// End-to-end tests requiring a running LiveKit server.
    @Tag static var e2e: Self
    /// End-to-end encryption tests.
    @Tag static var e2ee: Self
    /// Codec, track, publishing, and AVFoundation tests.
    @Tag static var media: Self
    /// Region management, token, and connection tests.
    @Tag static var networking: Self
    /// RPC v1 / v2 caller and handler tests.
    @Tag static var rpc: Self
}

/// Limits shared by the Core suites.
enum TestLimits {
    /// The wall-clock budget for one end-to-end test case, applied at suite level to every `.e2e`
    /// suite. A suite-level time limit bounds each of the suite's test cases individually, so a
    /// parameterized test gets the full budget per argument.
    ///
    /// Generous on purpose. The slowest single case seen on the slowest legs runs about 80 s, and
    /// a case that passes on a degraded runner can also absorb the one-off 90 s server readiness
    /// wait and the harness's 36 s of connect retries. What this exists for is the hang — a wait
    /// nothing can resume — which otherwise costs a leg the whole of its step budget.
    ///
    /// `TimeLimitTrait` needs iOS 16 and the package deploys to iOS 13, so this resolves the trait
    /// at runtime: every host CI runs on gets the limit, and a host too old for the trait gets an
    /// inert empty tag list instead of a compile error.
    static var e2e: any SuiteTrait {
        if #available(iOS 16, macOS 13, tvOS 16, visionOS 1, *) {
            let limit: TimeLimitTrait = .timeLimit(.minutes(5))
            return limit
        }
        let none: Tag.List = .tags()
        return none
    }
}
