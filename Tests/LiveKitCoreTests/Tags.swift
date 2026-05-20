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
