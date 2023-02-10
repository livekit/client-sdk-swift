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
import Promises

public extension LocalParticipant {

    @discardableResult
    func set(source: Track.Source, enabled: Bool) async throws -> LocalTrackPublication? {

        try await withCheckedThrowingContinuation { continuation in
            set(source: source, enabled: enabled).then(on: queue) { result in
                continuation.resume(returning: result)
            }.catch(on: queue) { error in
                continuation.resume(throwing: error)
            }
        }
    }

    @discardableResult
    func setCamera(enabled: Bool) async throws -> LocalTrackPublication? {
        try await set(source: .camera, enabled: enabled)
    }

    @discardableResult
    func setMicrophone(enabled: Bool) async throws -> LocalTrackPublication? {
        try await set(source: .microphone, enabled: enabled)
    }

    @discardableResult
    func setScreenShare(enabled: Bool) async throws -> LocalTrackPublication? {
        try await set(source: .screenShareVideo, enabled: enabled)
    }

    @discardableResult
    func publishVideo(_ track: LocalVideoTrack,
                      publishOptions: VideoPublishOptions? = nil) async throws -> LocalTrackPublication {

        try await withCheckedThrowingContinuation { continuation in
            publishVideoTrack(track: track, publishOptions: publishOptions).then(on: queue) { result in
                continuation.resume(returning: result)
            }.catch(on: queue) { error in
                continuation.resume(throwing: error)
            }
        }
    }

    @discardableResult
    func publishAudio(_ track: LocalAudioTrack,
                      publishOptions: AudioPublishOptions? = nil) async throws -> LocalTrackPublication {

        try await withCheckedThrowingContinuation { continuation in
            publishAudioTrack(track: track, publishOptions: publishOptions).then(on: queue) { result in
                continuation.resume(returning: result)
            }.catch(on: queue) { error in
                continuation.resume(throwing: error)
            }
        }
    }

    func publishData(_ data: Data,
                     reliability: Reliability = .reliable,
                     destination: [String] = []) async throws {

        try await withCheckedThrowingContinuation { continuation in
            publishData(data: data, reliability: reliability, destination: destination).then(on: queue) { result in
                continuation.resume(returning: result)
            }.catch(on: queue) { error in
                continuation.resume(throwing: error)
            }
        }
    }

    func unpublish(publication: LocalTrackPublication, notify: Bool = true) async throws {

        try await withCheckedThrowingContinuation { continuation in
            unpublish(publication: publication, notify: notify).then(on: queue) {
                continuation.resume()
            }.catch(on: queue) { error in
                continuation.resume(throwing: error)
            }
        }
    }

    func unpublishAll(notify: Bool = true) async throws {

        try await withCheckedThrowingContinuation { continuation in
            unpublishAll(notify: notify).then(on: queue) {
                continuation.resume()
            }.catch(on: queue) { error in
                continuation.resume(throwing: error)
            }
        }
    }

    func setTrackSubscriptionPermissions(allParticipantsAllowed: Bool,
                                         trackPermissions: [ParticipantTrackPermission] = []) async throws {

        try await withCheckedThrowingContinuation { continuation in
            setTrackSubscriptionPermissions(allParticipantsAllowed: allParticipantsAllowed,
                                            trackPermissions: trackPermissions).then(on: queue) {
                                                continuation.resume()
                                            }.catch(on: queue) { error in
                                                continuation.resume(throwing: error)
                                            }
        }
    }
}
