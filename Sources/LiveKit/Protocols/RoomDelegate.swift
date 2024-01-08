/*
 * Copyright 2024 LiveKit
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
public protocol RoomDelegate: AnyObject {
    // MARK: - Room

    @objc(room:didUpdateConnectionState:oldConnectionState:) optional
    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, oldConnectionState: ConnectionState)

    /// Successfully connected to the room.
    @objc(roomDidConnect:) optional
    func roomDidConnect(_ room: Room)

    /// Successfully re-connected to the room.
    @objc(roomIsReconnecting:) optional
    func roomIsReconnecting(_ room: Room)

    /// Successfully re-connected to the room.
    @objc(roomDidReconnect:) optional
    func roomDidReconnect(_ room: Room)

    /// Could not connect to the room. Only triggered when the initial connect attempt fails.
    @objc(room:didFailToConnectWithError:) optional
    func room(_ room: Room, didFailToConnectWithError error: LiveKitError?)

    /// Client disconnected from the room unexpectedly after a successful connection.
    @objc(room:didDisconnectWithError:) optional
    func room(_ room: Room, didDisconnectWithError error: LiveKitError?)

    /// ``Room``'s id has been updated after a successful connection.
    @objc(room:didUpdateRoomId:) optional
    func room(_ room: Room, didUpdateRoomId roomId: String)

    /// ``Room``'s metadata has been updated.
    @objc(room:didUpdateMetadata:) optional
    func room(_ room: Room, didUpdateMetadata metadata: String?)

    /// ``Room``'s recording state has been updated.
    @objc(room:didUpdateIsRecording:) optional
    func room(_ room: Room, didUpdateIsRecording isRecording: Bool)

    // MARK: - Participant

    /// When a ``RemoteParticipant`` joins after the ``LocalParticipant``.
    /// It will not emit events for participants that are already in the room.
    @objc(room:participantDidConnect:) optional
    func room(_ room: Room, remoteParticipantDidConnect remoteParticipant: RemoteParticipant)

    /// When a ``RemoteParticipant`` leaves after the ``LocalParticipant`` has joined.
    @objc(room:participantDidDisconnect:) optional
    func room(_ room: Room, remoteParticipantDidDisconnect remoteParticipant: RemoteParticipant)

    /// Active speakers changed.
    ///
    /// List of speakers are ordered by their ``Participant/audioLevel``, loudest speakers first.
    /// This will include the ``LocalParticipant`` too.
    @objc(room:didUpdateSpeakingParticipants:) optional
    func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant])

    /// Same with ``ParticipantDelegate/participant(_:didUpdateMetadata:)``.
    @objc(room:participant:didUpdateMetadata:) optional
    func room(_ room: Room, participant: Participant, didUpdateMetadata: String?)

    /// Same with ``ParticipantDelegate/participant(_:didUpdateName:)``.
    @objc(room:participant:didUpdateName:) optional
    func room(_ room: Room, participant: Participant, didUpdateName: String?)

    /// Same with ``ParticipantDelegate/participant(_:didUpdateConnectionQuality:)``.
    @objc(room:participant:didUpdateConnectionQuality:) optional
    func room(_ room: Room, participant: Participant, didUpdateConnectionQuality connectionQuality: ConnectionQuality)

    /// Same with ``ParticipantDelegate/participant(_:track:didUpdateIsMuted:)``.
    @objc(room:participant:track:didUpdateIsMuted:) optional
    func room(_ room: Room, participant: Participant, track: TrackPublication, didUpdateIsMuted isMuted: Bool)

    @objc(room:participant:didUpdatePermissions:) optional
    func room(_ room: Room, participant: Participant, didUpdatePermissions permissions: ParticipantPermissions)

    // MARK: - LocalTrackPublication

    /// Same with ``ParticipantDelegate/localParticipant(_:didPublishTrack:)``.
    @objc(room:localParticipant:didPublishTrack:) optional
    func room(_ room: Room, localParticipant: LocalParticipant, didPublishTrack publication: LocalTrackPublication)

    /// Same with ``ParticipantDelegate/localParticipant(_:didUnpublishTrack:)``.
    @objc(room:localParticipant:didUnpublishTrack:) optional
    func room(_ room: Room, localParticipant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication)

    // MARK: - RemoteTrackPublication

    /// Same with ``ParticipantDelegate/participant(_:didPublishPublication:)``.
    @objc(room:remoteParticipant:didPublishTrack:) optional
    func room(_ room: Room, remoteParticipant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didUnpublishPublication:)``.
    @objc(room:remoteParticipant:didUnpublishTrack:) optional
    func room(_ room: Room, remoteParticipant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didSubscribePublication:)``.
    @objc(room:remoteParticipant:didSubscribeTrack:) optional
    func room(_ room: Room, remoteParticipant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didUnsubscribePublication:)``.
    @objc(room:remoteParticipant:didUnsubscribeTrack:) optional
    func room(_ room: Room, remoteParticipant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didUpdatePublication:streamState:)``.
    @objc(room:remoteParticipant:track:didUpdateStreamState:) optional
    func room(_ room: Room, remoteParticipant: RemoteParticipant, track: RemoteTrackPublication, didUpdateStreamState streamState: StreamState)

    /// Same with ``ParticipantDelegate/participant(_:didUpdatePublication:isSubscriptionAllowed:)``.
    @objc(room:remoteParticipant:track:didUpdateIsSubscriptionAllowed:) optional
    func room(_ room: Room, remoteParticipant: RemoteParticipant, track: RemoteTrackPublication, didUpdateIsSubscriptionAllowed isSubscriptionAllowed: Bool)

    /// Same with ``ParticipantDelegate/participant(_:didFailToSubscribe:error:)``.
    @objc(room:remoteParticipant:didFailToSubscribeTrack:withError:) optional
    func room(_ room: Room, remoteParticipant: RemoteParticipant, didFailToSubscribeTrack trackSid: String, withError error: LiveKitError)

    // MARK: - Data

    /// Same with ``ParticipantDelegate/participant(_:didReceiveData:topic:)``
    /// participant could be nil if data was sent by server api.
    @objc(room:participant:didReceiveData:forTopic:) optional
    func room(_ room: Room, remoteParticipant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String)

    // MARK: - E2EE

    /// ``Room``'e2ee state has been updated.
    @objc(room:track:didUpdateE2EEState:) optional
    func room(_ room: Room, track: TrackPublication, didUpdateE2EEState e2eeState: E2EEState)
}
