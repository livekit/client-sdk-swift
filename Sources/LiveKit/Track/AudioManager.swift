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

// Audio Session Configuration related
public class AudioManager: Loggable {

    // MARK: - Public

    public static let shared = AudioManager()

    public enum State {
        case none
        case localOnly
        case remoteOnly
        case localAndRemote
    }

    public struct AudioManagerState {
        var localTracksCount: Int = 0
        var remoteTracksCount: Int = 0
        var preferSpeakerOutput: Bool = true
    }

    //    public private(set) var state: State = .none {
    //        didSet {
    //            guard oldValue != state else { return }
    //            log("AudioManager.state didUpdate \(oldValue) -> \(state)")
    //            #if os(iOS)
    //            LiveKit.onShouldConfigureAudioSession(state, oldValue)
    //            #endif
    //        }
    //    }

    //    public var audioTrackState: State {
    //
    //        _state.read { state in
    //
    //
    //        }
    //    }

    public var localTracksCount: Int { _state.localTracksCount }
    public var remoteTracksCount: Int { _state.remoteTracksCount }
    public var preferSpeakerOutput: Bool {
        get { _state.preferSpeakerOutput }
        set { _state.mutate { $0.preferSpeakerOutput = newValue } }
    }

    // MARK: - Internal

    internal enum `Type` {
        case local
        case remote
    }

    // MARK: - Private

    private var _state = StateSync(AudioManagerState())

    private let configureQueue = DispatchQueue(label: "LiveKitSDK.AudioManager.configure", qos: .default)
    private let notificationQueue = OperationQueue()
    private var routeChangeObserver: NSObjectProtocol?

    // Singleton
    private init() {

        #if os(iOS)
        //
        routeChangeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                                     object: nil,
                                                                     queue: notificationQueue) { [weak self] notification in
            //
            guard let self = self else { return }
            self.log("AVAudioSession.routeChangeNotification \(String(describing: notification.userInfo))")

            guard let number = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber?,
                  let uint = number?.uintValue,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: uint)  else { return }

            switch reason {
            case .newDeviceAvailable:
                self.log("newDeviceAvailable")
            case .categoryChange:
                self.log("categoryChange")

                let session: RTCAudioSession = DispatchQueue.webRTC.sync {
                    let result = RTCAudioSession.sharedInstance()
                    result.lockForConfiguration()
                    return result
                }

                defer { DispatchQueue.webRTC.sync { session.unlockForConfiguration() } }

                do {
                    try session.overrideOutputAudioPort(self._state.preferSpeakerOutput ? .speaker : .none)
                } catch let error {
                    self.log("failed to update output with error: \(error)")
                }
            default: break
            }
        }
        #endif

        // trigger events when state mutates
        _state.onMutate = { [weak self] newState, oldState in
            guard let self = self else { return }
            self.configureQueue.async {
                self.reconfigureAudioSession(newState: newState, oldState: oldState)
            }
        }
    }

    deinit {
        // remove the route change observer
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    internal func trackDidStart(_ type: Type) {
        // async mutation
        _state.mutateAsync { state in
            if type == .local { state.localTracksCount += 1 }
            if type == .remote { state.remoteTracksCount += 1 }
        }
    }

    internal func trackDidStop(_ type: Type) {
        // async mutation
        _state.mutateAsync { state in
            if type == .local { state.localTracksCount -= 1 }
            if type == .remote { state.remoteTracksCount -= 1 }
        }
    }

    private func reconfigureAudioSession(newState: AudioManagerState,
                                         oldState: AudioManagerState) {
        log("\(oldState) -> \(newState)")
        defaultShouldConfigureAudioSessionFunc(newState: newState,
                                               oldState: oldState)
    }

    #if os(iOS)
    /// Configure the `RTCAudioSession` of `WebRTC` framework.
    ///
    /// > Note: It is recommended to use `RTCAudioSessionConfiguration.webRTC()` to obtain an instance of `RTCAudioSessionConfiguration` instead of instantiating directly.
    ///
    /// View ``defaultShouldConfigureAudioSessionFunc(newState:oldState:)`` for usage of this method.
    ///
    /// - Parameters:
    ///   - configuration: A configured RTCAudioSessionConfiguration
    ///   - setActive: passing true/false will call `AVAudioSession.setActive` internally
    public func configureAudioSession(_ configuration: RTCAudioSessionConfiguration,
                                      setActive: Bool? = nil) {

        let session: RTCAudioSession = DispatchQueue.webRTC.sync {
            let result = RTCAudioSession.sharedInstance()
            result.lockForConfiguration()
            return result
        }

        defer { DispatchQueue.webRTC.sync { session.unlockForConfiguration() } }

        do {
            logger.log("configuring audio session with category: \(configuration.category), mode: \(configuration.mode), setActive: \(String(describing: setActive))", type: LiveKit.self)

            if let setActive = setActive {
                try DispatchQueue.webRTC.sync { try session.setConfiguration(configuration, active: setActive) }
            } else {
                try DispatchQueue.webRTC.sync { try session.setConfiguration(configuration) }
            }
        } catch let error {
            logger.log("Failed to configureAudioSession with error: \(error)", .error, type: LiveKit.self)
        }
    }

    /// The default implementation when audio session configuration is requested by the SDK.
    public func defaultShouldConfigureAudioSessionFunc(newState: AudioManagerState,
                                                       oldState: AudioManagerState) {

        let config = DispatchQueue.webRTC.sync { RTCAudioSessionConfiguration.webRTC() }

        var categoryOptions: AVAudioSession.CategoryOptions = []

        switch newState.audioTrackState {
        case .remoteOnly:
            config.category = AVAudioSession.Category.playback.rawValue
            config.mode = AVAudioSession.Mode.spokenAudio.rawValue
        case .localOnly, .localAndRemote:
            config.category = AVAudioSession.Category.playAndRecord.rawValue
            config.mode = AVAudioSession.Mode.videoChat.rawValue

            categoryOptions = [.allowBluetooth, .allowBluetoothA2DP]

            if newState.preferSpeakerOutput {
                categoryOptions.insert(.defaultToSpeaker)
            }

        default:
            config.category = AVAudioSession.Category.soloAmbient.rawValue
            config.mode = AVAudioSession.Mode.default.rawValue
        }

        config.categoryOptions = categoryOptions

        var setActive: Bool?
        if newState.audioTrackState != .none, oldState.audioTrackState == .none {
            // activate audio session when there is any local/remote audio track
            setActive = true
        } else if newState.audioTrackState == .none, oldState.audioTrackState != .none {
            // deactivate audio session when there are no more local/remote audio tracks
            setActive = false
        }

        AudioManager.shared.configureAudioSession(config, setActive: setActive)
    }
    #endif
}

extension AudioManager.AudioManagerState {

    public var audioTrackState: AudioManager.State {

        if localTracksCount > 0 && remoteTracksCount == 0 {
            return .localOnly
        } else if localTracksCount == 0 && remoteTracksCount > 0 {
            return .remoteOnly
        } else if localTracksCount > 0 && remoteTracksCount > 0 {
            return .localAndRemote
        }

        return .none
    }
}
