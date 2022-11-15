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
import SwiftUI
import WebRTC
import Promises

open class ObservableRoom: ObservableObject, RoomDelegate, Loggable {

    public let room: Room

    public var connectionState: ConnectionState {
        room.connectionState
    }

    public var metadata: String? {
        room.metadata
    }

    public var remoteParticipants: [Sid: ObservableParticipant] {
        Dictionary(uniqueKeysWithValues: room.remoteParticipants.map { (sid, participant) in (sid, ObservableParticipant(participant)) })
    }

    public var allParticipants: [Sid: ObservableParticipant] {
        var result = remoteParticipants

        if let localParticipant = room.localParticipant {
            result.updateValue(ObservableParticipant(localParticipant),
                               forKey: localParticipant.sid)
        }

        return result
    }

    @Published public var cameraTrackState: TrackPublishState = .notPublished()
    @Published public var microphoneTrackState: TrackPublishState = .notPublished()
    @Published public var screenShareTrackState: TrackPublishState = .notPublished()

    public init(_ room: Room = Room()) {
        self.room = room
        room.add(delegate: self)
    }

    @discardableResult
    public func switchCameraPosition() -> Promise<Bool> {

        guard case .published(let publication) = self.cameraTrackState,
              let track = publication.track as? LocalVideoTrack,
              let cameraCapturer = track.capturer as? CameraCapturer else {
            log("Track or CameraCapturer doesn't exist", .notice)
            return Promise(TrackError.state(message: "Track or a CameraCapturer doesn't exist"))
        }

        return cameraCapturer.switchCameraPosition()
    }

    public func toggleCameraEnabled() {

        guard let localParticipant = room.localParticipant else {
            log("LocalParticipant doesn't exist", .notice)
            return
        }

        guard !cameraTrackState.isBusy else {
            log("cameraTrack is .busy", .notice)
            return
        }

        DispatchQueue.main.async {
            self.cameraTrackState = .busy(isPublishing: !self.cameraTrackState.isPublished)
        }

        localParticipant.setCamera(enabled: !localParticipant.isCameraEnabled()).then(on: room.queue) { publication in
            DispatchQueue.main.async {
                guard let publication = publication else { return }
                self.cameraTrackState = .published(publication)
            }
            self.log("Successfully published camera")
        }.catch(on: room.queue) { error in
            DispatchQueue.main.async {
                self.cameraTrackState = .notPublished(error: error)
            }
            self.log("Failed to publish camera, error: \(error)")
        }
    }

    public func toggleScreenShareEnabled() {

        guard let localParticipant = room.localParticipant else {
            log("LocalParticipant doesn't exist", .notice)
            return
        }

        guard !screenShareTrackState.isBusy else {
            log("screenShareTrack is .busy", .notice)
            return
        }

        DispatchQueue.main.async {
            self.screenShareTrackState = .busy(isPublishing: !self.screenShareTrackState.isPublished)
        }

        localParticipant.setScreenShare(enabled: !localParticipant.isScreenShareEnabled()).then(on: room.queue) { publication in
            DispatchQueue.main.async {
                guard let publication = publication else { return }
                self.screenShareTrackState = .published(publication)
            }
        }.catch(on: room.queue) { error in
            DispatchQueue.main.async {
                self.screenShareTrackState = .notPublished(error: error)
            }
        }
    }

    public func toggleMicrophoneEnabled() {

        guard let localParticipant = room.localParticipant else {
            log("LocalParticipant doesn't exist", .notice)
            return
        }

        guard !microphoneTrackState.isBusy else {
            log("microphoneTrack is .busy", .notice)
            return
        }

        DispatchQueue.main.async {
            self.microphoneTrackState = .busy(isPublishing: !self.microphoneTrackState.isPublished)
        }

        localParticipant.setMicrophone(enabled: !localParticipant.isMicrophoneEnabled()).then(on: room.queue) { publication in
            DispatchQueue.main.async {
                guard let publication = publication else { return }
                self.microphoneTrackState = .published(publication)
            }
            self.log("Successfully published microphone")
        }.catch(on: room.queue) { error in
            DispatchQueue.main.async {
                self.microphoneTrackState = .notPublished(error: error)
            }
            self.log("Failed to publish microphone, error: \(error)")
        }
    }

    // MARK: - RoomDelegate

    open func room(_ room: Room, didUpdate connectionState: ConnectionState, oldValue: ConnectionState) {

        DispatchQueue.main.async {
            if case .disconnected = connectionState {
                self.cameraTrackState = .notPublished()
                self.microphoneTrackState = .notPublished()
                self.screenShareTrackState = .notPublished()
            }
            self.objectWillChange.send()
        }
    }

    open func room(_ room: Room,
                   participantDidJoin participant: RemoteParticipant) {
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    open func room(_ room: Room,
                   participantDidLeave participant: RemoteParticipant) {
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    open func room(_ room: Room, participant: Participant, didUpdate metadata: String?) {
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    open func room(_ room: Room, didConnect isReconnect: Bool) {}
    open func room(_ room: Room, didFailToConnect error: Error) {}
    open func room(_ room: Room, didDisconnect error: Error?) {}
    open func room(_ room: Room, didUpdate speakers: [Participant]) {}
    open func room(_ room: Room, didUpdate metadata: String?) {}
    open func room(_ room: Room, participant: Participant, didUpdate connectionQuality: ConnectionQuality) {}
    open func room(_ room: Room, participant: Participant, didUpdate publication: TrackPublication, muted: Bool) {}
    open func room(_ room: Room, participant: Participant, didUpdate permissions: ParticipantPermissions) {}
    open func room(_ room: Room, participant: RemoteParticipant, didUpdate publication: RemoteTrackPublication, streamState: StreamState) {}
    open func room(_ room: Room, participant: RemoteParticipant, didPublish publication: RemoteTrackPublication) {}
    open func room(_ room: Room, participant: RemoteParticipant, didUnpublish publication: RemoteTrackPublication) {}
    open func room(_ room: Room, participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track: Track) {}
    open func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribe trackSid: String, error: Error) {}
    open func room(_ room: Room, participant: RemoteParticipant, didUnsubscribe publication: RemoteTrackPublication, track: Track) {}
    open func room(_ room: Room, participant: RemoteParticipant?, didReceive data: Data) {}
    open func room(_ room: Room, localParticipant: LocalParticipant, didPublish publication: LocalTrackPublication) {}
    open func room(_ room: Room, localParticipant: LocalParticipant, didUnpublish publication: LocalTrackPublication) {}
    open func room(_ room: Room, participant: RemoteParticipant, didUpdate publication: RemoteTrackPublication, permission allowed: Bool) {}
}
