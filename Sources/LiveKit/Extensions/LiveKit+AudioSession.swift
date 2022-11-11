/*
 * Copyright 2022 LiveKit
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
import WebRTC

/// Function type for `LiveKit.onShouldConfigureAudioSession`.
/// - Parameters:
///   - newState: The new state of audio tracks
///   - oldState: The previous state of audio tracks
@available(*, deprecated, message: "Moved to AudioManager.ConfigureAudioSessionFunc")
public typealias ShouldConfigureAudioSessionFunc = (_ newState: AudioManager.TrackState,
                                                    _ oldState: AudioManager.TrackState) -> Void

extension LiveKit {

    #if os(iOS)
    /// Called when audio session configuration is suggested by the SDK.
    ///
    /// By default, ``defaultShouldConfigureAudioSessionFunc(newState:oldState:)`` is used and this
    /// will be handled automatically.
    ///
    /// To change the default behavior, set this to your own ``ShouldConfigureAudioSessionFunc`` function and call
    /// ``configureAudioSession(_:setActive:)`` with your own configuration.
    ///
    /// View ``defaultShouldConfigureAudioSessionFunc(newState:oldState:)`` for the default implementation.
    ///
    @available(*, deprecated, message: "Use AudioManager.shared.customConfigureFunc instead")
    public static var onShouldConfigureAudioSession: ShouldConfigureAudioSessionFunc?

    #endif
}
