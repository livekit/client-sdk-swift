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

    public typealias ConfigureAudioSessionFunc = (_ newState: State,
                                                  _ oldState: State) -> Void

    public var customConfigureFunc: ConfigureAudioSessionFunc?

    public enum TrackState {
        case none
        case localOnly
        case remoteOnly
        case localAndRemote
    }

    public struct State {
        var localTracksCount: Int = 0
        var remoteTracksCount: Int = 0
        var preferSpeakerOutput: Bool = false
    }

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

    private var _state = StateSync(State())
    private let configureQueue = DispatchQueue(label: "LiveKitSDK.AudioManager.configure", qos: .default)

    #if os(iOS)
    private let notificationQueue = OperationQueue()
    private var routeChangeObserver: NSObjectProtocol?
    #endif

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
            default: break
            }
        }
        #endif

        // trigger events when state mutates
        _state.onMutate = { [weak self] newState, oldState in
            guard let self = self else { return }
            self.configureQueue.async {
                self.configureAudioSession(newState: newState, oldState: oldState)
            }
        }
    }

    deinit {
        #if os(iOS)
        // remove the route change observer
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
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

    private func configureAudioSession(newState: State,
                                       oldState: State) {
        log("\(oldState) -> \(newState)")

        #if os(iOS)
        if let _deprecatedFunc = LiveKit.onShouldConfigureAudioSession {
            _deprecatedFunc(newState.trackState, oldState.trackState)
        } else if let customConfigureFunc = customConfigureFunc {
            customConfigureFunc(newState, oldState)
        } else {
            defaultShouldConfigureAudioSessionFunc(newState: newState,
                                                   oldState: oldState)
        }
        #endif
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
                                      setActive: Bool? = nil,
                                      preferSpeakerOutput: Bool = true) {

        let session: RTCAudioSession = DispatchQueue.webRTC.sync {
            let result = RTCAudioSession.sharedInstance()
            result.lockForConfiguration()
            return result
        }

        defer { DispatchQueue.webRTC.sync { session.unlockForConfiguration() } }

        do {
            logger.log("configuring audio session with category: \(configuration.category), mode: \(configuration.mode), setActive: \(String(describing: setActive))", type: AudioManager.self)

            if let setActive = setActive {
                try DispatchQueue.webRTC.sync { try session.setConfiguration(configuration, active: setActive) }
            } else {
                try DispatchQueue.webRTC.sync { try session.setConfiguration(configuration) }
            }

        } catch let error {
            logger.log("Failed to configureAudioSession with error: \(error)", .error, type: AudioManager.self)
        }

        do {
            logger.log("preferSpeakerOutput: \(preferSpeakerOutput)", type: AudioManager.self)
            try DispatchQueue.webRTC.sync { try session.overrideOutputAudioPort(preferSpeakerOutput ? .speaker : .none) }
        } catch let error {
            logger.log("Failed to overrideOutputAudioPort with error: \(error)", .error, type: AudioManager.self)
        }
    }

    /// The default implementation when audio session configuration is requested by the SDK.
    public func defaultShouldConfigureAudioSessionFunc(newState: State,
                                                       oldState: State) {

        let config = DispatchQueue.webRTC.sync { RTCAudioSessionConfiguration.webRTC() }

        var categoryOptions: AVAudioSession.CategoryOptions = []

        switch newState.trackState {
        case .remoteOnly:
            config.category = AVAudioSession.Category.playback.rawValue
            config.mode = AVAudioSession.Mode.spokenAudio.rawValue
        case  .localOnly, .localAndRemote:
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
        if newState.trackState != .none, oldState.trackState == .none {
            // activate audio session when there is any local/remote audio track
            setActive = true
        } else if newState.trackState == .none, oldState.trackState != .none {
            // deactivate audio session when there are no more local/remote audio tracks
            setActive = false
        }

        configureAudioSession(config,
                              setActive: setActive,
                              preferSpeakerOutput: newState.preferSpeakerOutput)
    }
    #endif
}

extension AudioManager.State {

    public var trackState: AudioManager.TrackState {

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
