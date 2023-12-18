/*
 * Copyright 2023 LiveKit
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
    @objc(room:didConnectIsReconnect:) optional
    func room(_ room: Room, didConnect isReconnect: Bool)

    /// Could not connect to the room.
    @objc(room:didFailToConnectWithError:) optional
    func room(_ room: Room, didFailToConnectWithError error: LiveKitError?)

    /// Client disconnected from the room unexpectedly.
    @objc(room:didDisconnectWithError:) optional
    func room(_ room: Room, didDisconnectWithError error: LiveKitError?)

    /// ``Room``'s metadata has been updated.
    @objc(room:didUpdateMetadata:) optional
    func room(_ room: Room, didUpdateMetadata metadata: String?)

    /// ``Room``'s recording state has been updated.
    @objc(room:didUpdateIsRecording:) optional
    func room(_ room: Room, didUpdateIsRecording isRecording: Bool)

    // MARK: - Participant

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

    /// Same with ``ParticipantDelegate/participant(_:didUpdatePublication:isMuted:)``.
    @objc(room:participant:publication:didUpdateIsMuted:) optional
    func room(_ room: Room, participant: Participant, didUpdatePublication publication: TrackPublication, isMuted: Bool)

    @objc(room:participant:didUpdatePermissions:) optional
    func room(_ room: Room, participant: Participant, didUpdatePermissions permissions: ParticipantPermissions)

    // MARK: - LocalTrackPublication

    /// Same with ``ParticipantDelegate/localParticipant(_:didPublishPublication:)``.
    @objc(room:localParticipant:didPublishPublication:) optional
    func room(_ room: Room, localParticipant: LocalParticipant, didPublishPublication publication: LocalTrackPublication)

    /// Same with ``ParticipantDelegate/localParticipant(_:didUnpublishPublication:)``.
    @objc(room:localParticipant:didUnpublishPublication:) optional
    func room(_ room: Room, localParticipant: LocalParticipant, didUnpublishPublication publication: LocalTrackPublication)

    // MARK: - RemoteTrackPublication

    /// Same with ``ParticipantDelegate/participant(_:didPublishPublication:)``.
    @objc(room:participant:didPublishPublication:) optional
    func room(_ room: Room, participant: RemoteParticipant, didPublishPublication publication: RemoteTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didUnpublishPublication:)``.
    @objc(room:participant:didUnpublishPublication:) optional
    func room(_ room: Room, participant: RemoteParticipant, didUnpublishPublication publication: RemoteTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didSubscribePublication:)``.
    @objc(room:participant:didSubscribePublication:) optional
    func room(_ room: Room, participant: RemoteParticipant, didSubscribePublication publication: RemoteTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didUnsubscribePublication:)``.
    @objc(room:publication:didUnsubscribePublication:) optional
    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribePublication publication: RemoteTrackPublication)

    /// Same with ``ParticipantDelegate/participant(_:didUpdatePublication:streamState:)``.
    @objc(room:participant:publication:didUpdateStreamState:) optional
    func room(_ room: Room, participant: RemoteParticipant, didUpdatePublication publication: RemoteTrackPublication, streamState: StreamState)

    /// Same with ``ParticipantDelegate/participant(_:didUpdatePublication:isSubscriptionAllowed:)``.
    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, didUpdatePublication publication: RemoteTrackPublication, isSubscriptionAllowed: Bool)

    /// Same with ``ParticipantDelegate/participant(_:didFailToSubscribe:error:)``.
    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribe trackSid: String, error: LiveKitError)

    // MARK: - Data

    /// Same with ``ParticipantDelegate/participant(_:didReceiveData:topic:)``
    /// participant could be nil if data was sent by server api.
    @objc(room:participant:didReceiveData:topic:) optional
    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, topic: String)

    // MARK: - E2EE

    /// ``Room``'e2ee state has been updated.
    @objc(room:publication:didUpdateE2EEState:) optional
    func room(_ room: Room, publication: TrackPublication, didUpdateE2EEState e2eeState: E2EEState)
}
