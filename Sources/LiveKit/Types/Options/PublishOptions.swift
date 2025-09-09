/*
 * Copyright 2025 LiveKit
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

/// Base protocol for ``DataPublishOptions`` and ``MediaPublishOptions``.
@objc
public protocol PublishOptions {}

/// Base protocol for both ``VideoPublishOptions`` and ``AudioPublishOptions``.
@objc
public protocol TrackPublishOptions: PublishOptions, Sendable {
    var name: String? { get }
    /// Set stream name for the track. Audio and video tracks with the same stream name
    /// will be placed in the same `MediaStream` and offer better synchronization.
    /// By default, camera and microphone will be placed in a stream; as would screen_share and screen_share_audio
    var streamName: String? { get }
}
