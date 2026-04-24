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

internal import LiveKitUniFFI

// Internal type aliases for data track types from LiveKitUniFFI.
// Tests access these via `@testable import LiveKit` or direct `import LiveKitUniFFI`.
typealias DataTrackFrame = LiveKitUniFFI.DataTrackFrame
typealias DataTrackInfo = LiveKitUniFFI.DataTrackInfo
typealias DataTrackOptions = LiveKitUniFFI.DataTrackOptions
typealias LocalDataTrack = LiveKitUniFFI.LocalDataTrack
typealias RemoteDataTrack = LiveKitUniFFI.RemoteDataTrack
typealias DataTrackStream = LiveKitUniFFI.DataTrackStream
typealias PushFrameErrorReason = LiveKitUniFFI.PushFrameErrorReason
typealias PublishDataTrackError = LiveKitUniFFI.PublishError
typealias DataTrackSubscribeError = LiveKitUniFFI.DataTrackSubscribeError

// MARK: - AsyncPolling Conformance

extension LiveKitUniFFI.DataTrackStream: AsyncPolling {
    typealias Element = LiveKitUniFFI.DataTrackFrame
}
