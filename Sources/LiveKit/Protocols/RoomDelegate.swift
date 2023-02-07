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

/// ``RoomDelegate`` receives room events as well as ``Participant`` events.
///
/// > Important: The thread which the delegate will be called on, is not guranteed to be the `main` thread.
/// If you will perform any UI update from the delegate, ensure the execution is from the `main` thread.
///
/// ## Example usage
/// ```swift
/// func room(_ room: Room, localParticipant: LocalParticipant, didPublish publication: LocalTrackPublication) {
///   DispatchQueue.main.async {
///     // update UI here
///     self.localVideoView.isHidden = false
///   }
/// }
/// ```
/// See the source code of [Swift Example App](https://github.com/livekit/client-example-swift) for more examples.
@objc
public protocol RoomDelegateObjC: AnyObject {

    @objc(room:didUpdateConnectionState:oldConnectionState:) optional
    func room(_ room: Room, didUpdate connectionState: ConnectionStateObjC, oldValue oldConnectionState: ConnectionStateObjC)

    /// Successfully connected to the room.
    @objc(room:didConnectIsReconnect:) optional
    func room(_ room: Room, didConnect isReconnect: Bool)

    /// Could not connect to the room.
    @objc(room:didFailToConnectWithError:) optional
    func room(_ room: Room, didFailToConnect error: Error)

    /// Client disconnected from the room unexpectedly.
    @objc(room:didDisconnectWithError:) optional
    func room(_ room: Room, didDisconnect error: Error?)

    /// When a ``RemoteParticipant`` joins after the ``LocalParticipant``.
    /// It will not emit events for participants that are already in the room.
    @objc(room:participantDidJoin:) optional
    func room(_ room: Room, participantDidJoin participant: RemoteParticipant)

    /// When a ``RemoteParticipant`` leaves after the ``LocalParticipant`` has joined.
    @objc(room:participantDidLeave:) optional
    func room(_ room: Room, participantDidLeave participant: RemoteParticipant)

    /// Active speakers changed.
    ///
    /// List of speakers are ordered by their ``Participant/audioLevel``, loudest speakers first.
    /// This will include the ``LocalParticipant`` too.
    @objc(room:didUpdateSpeakers:) optional
    func room(_ room: Room, didUpdate speakers: [Participant])

    /// ``Room``'s metadata has been updated.
    @objc(room:didUpdateMetadata:) optional
    func room(_ room: Room, didUpdate metadata: String?)

    /// ``Room``'s recording state has been updated.
    @objc(room:didUpdateIsRecording:) optional
    func room(_ room: Room, didUpdate isRecording: Bool)

    /// Same with ``ParticipantDelegate/participant(_:didUpdate:)-46iut``.
    @objc(room:participant:didUpdateMetadata:) optional
    func room(_ room: Room, participant: Participant, didUpdate metadata: String?)

    /// Same with ``ParticipantDelegate/participant(_:didUpdate:)-7zxk1``.
    @objc(room:participant:didUpdateConnectionQuality:) optional
    func room(_ room: Room, participant: Participant, didUpdate connectionQuality: ConnectionQuality)

    /// Same with ``ParticipantDelegate/participant(_:didUpdate:)-84m89``.
    @objc(room:participant:publication:didUpdateMuted:) optional
    func room(_ room: Room, participant: Participant, didUpdate publication: TrackPublication, muted: Bool)

    @objc(room:participant:didUpdatePermissions:) optional
    func room(_ room: Room, participant: Participant, didUpdate permissions: ParticipantPermissions)

    /// Same with ``ParticipantDelegate/participant(_:didUpdate:streamState:)-1lu8t``.
    @objc(room:participant:publication:didUpdateStreamState:) optional
    func room(_ room: Room, participant: RemoteParticipant, didUpdate publication: RemoteTrackPublication, streamState: StreamState)

    /// Same with ``ParticipantDelegate/participant(_:didPublish:)-60en3``.
    @objc(room:participant:didPublishPublication:) optional
    func room(_ room: Room, participant: RemoteParticipant, didPublish publication: RemoteTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didUnpublish:)-3bkga``.
    @objc(room:participant:didUnpublishPublication:) optional
    func room(_ room: Room, participant: RemoteParticipant, didUnpublish publication: RemoteTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didSubscribe:track:)-7mngl``.
    @objc(room:participant:didSubscribePublication:track:) optional
    func room(_ room: Room, participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track: Track)

    /// Same with ``ParticipantDelegate/participant(_:didFailToSubscribe:error:)-10pn4``.
    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribe trackSid: String, error: Error)

    /// Same with ``ParticipantDelegate/participant(_:didUnsubscribe:track:)-3ksvp``.
    @objc(room:publication:didUnsubscribePublication:track:) optional
    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribe publication: RemoteTrackPublication, track: Track)

    /// Same with ``ParticipantDelegate/participant(_:didReceive:)-2t55a``
    /// participant could be nil if data was sent by server api.
    @objc(room:participant:didReceiveData:) optional
    func room(_ room: Room, participant: RemoteParticipant?, didReceive data: Data)

    /// Same with ``ParticipantDelegate/localParticipant(_:didPublish:)-90j2m``.
    @objc(room:localParticipant:didPublishPublication:) optional
    func room(_ room: Room, localParticipant: LocalParticipant, didPublish publication: LocalTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didUnpublish:)-3bkga``.
    @objc(room:localParticipant:didUnpublishPublication:) optional
    func room(_ room: Room, localParticipant: LocalParticipant, didUnpublish publication: LocalTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didUpdate:permission:)``.
    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, didUpdate publication: RemoteTrackPublication, permission allowed: Bool)
}

public protocol RoomDelegate: RoomDelegateObjC {
    /// When the ``ConnectionState`` has updated.
    func room(_ room: Room, didUpdate connectionState: ConnectionState, oldValue: ConnectionState)
}

/// Default implementation for ``RoomDelegate``
public extension RoomDelegate {

    func room(_ room: Room, didUpdate connectionState: ConnectionState, oldValue: ConnectionState) {}
}
