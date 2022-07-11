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

    // TODO: Thread safety concerns
    public private(set) var state: State = .none {
        didSet {
            guard oldValue != state else { return }
            log("AudioManager.state didUpdate \(oldValue) -> \(state)")
            #if os(iOS)
            LiveKit.onShouldConfigureAudioSession(state, oldValue)
            #endif
        }
    }

    public private(set) var localTracksCount = 0 {
        didSet { recomputeState() }
    }

    public private(set) var remoteTracksCount = 0 {
        didSet { recomputeState() }
    }

    public var preferSpeakerOutput: Bool = true

    // MARK: - Internal

    internal enum `Type` {
        case local
        case remote
    }

    // MARK: - Private

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
                let session = RTCAudioSession.sharedInstance()
                do {
                    session.lockForConfiguration()
                    defer { session.unlockForConfiguration() }
                    try session.overrideOutputAudioPort(self.preferSpeakerOutput ? .speaker : .none)
                } catch let error {
                    self.log("failed to update output with error: \(error)")
                }
            default: break
            }
        }
        #endif
    }

    deinit {

        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    internal func trackDidStart(_ type: Type) {
        if type == .local { localTracksCount += 1 }
        if type == .remote { remoteTracksCount += 1 }
    }

    internal func trackDidStop(_ type: Type) {
        if type == .local { localTracksCount -= 1 }
        if type == .remote { remoteTracksCount -= 1 }

    }

    private func recomputeState() {
        if localTracksCount > 0 && remoteTracksCount == 0 {
            state = .localOnly
        } else if localTracksCount == 0 && remoteTracksCount > 0 {
            state = .remoteOnly
        } else if localTracksCount > 0 && remoteTracksCount > 0 {
            state = .localAndRemote
        } else {
            state = .none
        }
    }
}
