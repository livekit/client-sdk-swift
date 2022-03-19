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

import WebRTC

/// Function type for `LiveKit.onShouldConfigureAudioSession`.
/// - Parameters:
///   - newState: The new state of audio tracks
///   - oldState: The previous state of audio tracks
public typealias ShouldConfigureAudioSessionFunc = (_ newState: AudioManager.State,
                                                    _ oldState: AudioManager.State) -> Void

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
    public static var onShouldConfigureAudioSession: ShouldConfigureAudioSessionFunc = defaultShouldConfigureAudioSessionFunc

    /// Configure the `RTCAudioSession` of `WebRTC` framework.
    ///
    /// > Note: It is recommended to use `RTCAudioSessionConfiguration.webRTC()` to obtain an instance of `RTCAudioSessionConfiguration` instead of instantiating directly.
    ///
    /// View ``defaultShouldConfigureAudioSessionFunc(newState:oldState:)`` for usage of this method.
    ///
    /// - Parameters:
    ///   - configuration: A configured RTCAudioSessionConfiguration
    ///   - setActive: passing true/false will call `AVAudioSession.setActive` internally
    public static func configureAudioSession(_ configuration: RTCAudioSessionConfiguration,
                                             setActive: Bool? = nil) {

        let audioSession: RTCAudioSession = DispatchQueue.webRTC.sync {
            let result = RTCAudioSession.sharedInstance()
            result.lockForConfiguration()
            return result
        }

        defer { DispatchQueue.webRTC.sync { audioSession.unlockForConfiguration() } }

        do {
            logger.log("configuring audio session with category: \(configuration.category), mode: \(configuration.mode), setActive: \(String(describing: setActive))", type: LiveKit.self)

            if let setActive = setActive {
                try DispatchQueue.webRTC.sync { try audioSession.setConfiguration(configuration, active: setActive) }
            } else {
                try DispatchQueue.webRTC.sync { try audioSession.setConfiguration(configuration) }
            }
        } catch let error {
            logger.log("Failed to configureAudioSession with error: \(error)", .error, type: LiveKit.self)
        }
    }

    /// The default implementation when audio session configuration is requested by the SDK.
    public static func defaultShouldConfigureAudioSessionFunc(newState: AudioManager.State,
                                                              oldState: AudioManager.State) {

        let config = DispatchQueue.webRTC.sync { RTCAudioSessionConfiguration.webRTC() }

        switch newState {
        case .remoteOnly:
            config.category = AVAudioSession.Category.playback.rawValue
            config.mode = AVAudioSession.Mode.spokenAudio.rawValue
            config.categoryOptions = AVAudioSession.CategoryOptions.duckOthers
        case .localOnly, .localAndRemote:
            config.category = AVAudioSession.Category.playAndRecord.rawValue
            config.mode = AVAudioSession.Mode.videoChat.rawValue
            config.categoryOptions = AVAudioSession.CategoryOptions.duckOthers
        default:
            config.category = AVAudioSession.Category.soloAmbient.rawValue
            config.mode = AVAudioSession.Mode.default.rawValue
        }

        var setActive: Bool?
        if newState != .none, oldState == .none {
            // activate audio session when there is any local/remote audio track
            setActive = true
        } else if newState == .none, oldState != .none {
            // deactivate audio session when there are no more local/remote audio tracks
            setActive = false
        }

        configureAudioSession(config, setActive: setActive)
    }
    #endif
}
