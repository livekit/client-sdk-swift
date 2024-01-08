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
    // MARK: - Connection Events

    /// ``Room/connectionState`` has updated.
    @objc optional
    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState)

    /// Successfully connected to the room.
    @objc optional
    func roomDidConnect(_ room: Room)

    /// Previously connected to room but re-attempting to connect due to network issues.
    @objc optional
    func roomIsReconnecting(_ room: Room)

    /// Successfully re-connected to the room.
    @objc optional
    func roomDidReconnect(_ room: Room)

    /// Could not connect to the room. Only triggered when the initial connect attempt fails.
    @objc optional
    func room(_ room: Room, didFailToConnectWithError error: LiveKitError?)

    /// Client disconnected from the room unexpectedly after a successful connection.
    @objc optional
    func room(_ room: Room, didDisconnectWithError error: LiveKitError?)

    // MARK: - Room State Updates

    /// ``Room/sid`` has updated.
    @objc optional
    func room(_ room: Room, didUpdateRoomId roomId: String)

    /// ``Room/metadata`` has updated.
    @objc optional
    func room(_ room: Room, didUpdateMetadata metadata: String?)

    /// ``Room/isRecording`` has updated.
    @objc optional
    func room(_ room: Room, didUpdateIsRecording isRecording: Bool)

    // MARK: - Participant Management

    /// A ``RemoteParticipant`` joined the room.
    @objc optional
    func room(_ room: Room, participantDidConnect participant: RemoteParticipant)

    /// A ``RemoteParticipant`` left the room.
    @objc optional
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant)

    /// Speakers in the room has updated.
    @objc optional
    func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant])

    /// ``Participant/metadata`` has updated.
    @objc optional
    func room(_ room: Room, participant: Participant, didUpdateMetadata: String?)

    /// ``Participant/name`` has updated.
    @objc optional
    func room(_ room: Room, participant: Participant, didUpdateName: String?)

    /// ``Participant/connectionQuality`` has updated.
    @objc optional
    func room(_ room: Room, participant: Participant, didUpdateConnectionQuality quality: ConnectionQuality)

    /// ``Participant/permissions`` has updated.
    @objc optional
    func room(_ room: Room, participant: Participant, didUpdatePermissions permissions: ParticipantPermissions)

    // MARK: - Track Publications

    /// The ``LocalParticipant`` has published a ``LocalTrack``.
    @objc(room:localParticipant:didPublishTrack:) optional
    func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication)

    /// A ``RemoteParticipant`` has published a ``RemoteTrack``.
    @objc(room:remoteParticipant:didPublishTrack:) optional
    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication)

    /// The ``LocalParticipant`` has un-published a ``LocalTrack``.
    @objc(room:localParticipant:didUnpublishTrack:) optional
    func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication)

    /// A ``RemoteParticipant`` has un-published a ``RemoteTrack``.
    @objc(room:remoteParticipant:didUnpublishTrack:) optional
    func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication)

    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication)

    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication)

    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribeTrack: String, withError error: LiveKitError)

    // MARK: - Data and Encryption

    /// Received data from from a user or server. `participant` will be nil if broadcasted from server.
    @objc optional
    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String)

    @objc optional
    func room(_ room: Room, track: TrackPublication, didUpdateE2EEState state: E2EEState)

    /// ``TrackPublication/isMuted`` has updated.
    @objc optional
    func room(_ room: Room, participant: Participant, track: TrackPublication, didUpdateIsMuted isMuted: Bool)

    /// ``TrackPublication/streamState`` has updated.
    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, track: RemoteTrackPublication, didUpdateStreamState streamState: StreamState)

    /// ``RemoteTrackPublication/isSubscriptionAllowed`` has updated.
    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, track: RemoteTrackPublication, didUpdateIsSubscriptionAllowed isSubscriptionAllowed: Bool)
}
