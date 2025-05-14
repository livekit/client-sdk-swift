/*
 * Copyright 2025 LiveKit
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
public protocol RoomDelegate: AnyObject, Sendable {
    // MARK: - Connection Events

    /// ``Room/connectionState`` has updated.
    /// - Note: This method is not called for ``ReconnectMode/quick``, use ``RoomDelegate/room(_:didUpdateReconnectMode:)`` instead.
    @objc optional
    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState)

    /// Successfully connected to the room.
    @objc optional
    func roomDidConnect(_ room: Room)

    /// Previously connected to room but re-attempting to connect due to network issues.
    /// - Note: This method is not called for ``ReconnectMode/quick``, use ``RoomDelegate/room(_:didUpdateReconnectMode:)`` instead.
    @objc optional
    func roomIsReconnecting(_ room: Room)

    /// Successfully re-connected to the room.
    @objc optional
    func roomDidReconnect(_ room: Room)

    /// ``Room`` reconnect mode has updated.
    @objc optional
    func room(_ room: Room, didUpdateReconnectMode reconnectMode: ReconnectMode)

    /// Could not connect to the room. Only triggered when the initial connect attempt fails.
    @objc optional
    func room(_ room: Room, didFailToConnectWithError error: LiveKitError?)

    /// Client disconnected from the room unexpectedly after a successful connection.
    @objc optional
    func room(_ room: Room, didDisconnectWithError error: LiveKitError?)

    // MARK: - Room State Updates

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
    func room(_ room: Room, participant: Participant, didUpdateMetadata metadata: String?)

    /// ``Participant/name`` has updated.
    @objc optional
    func room(_ room: Room, participant: Participant, didUpdateName name: String)

    /// ``Participant/state`` has updated.
    @objc optional
    func room(_ room: Room, participant: Participant, didUpdateState state: ParticipantState)

    /// ``Participant/connectionQuality`` has updated.
    @objc optional
    func room(_ room: Room, participant: Participant, didUpdateConnectionQuality quality: ConnectionQuality)

    /// ``Participant/permissions`` has updated.
    @objc optional
    func room(_ room: Room, participant: Participant, didUpdatePermissions permissions: ParticipantPermissions)

    @objc optional
    func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String])

    /// Received transcription segments.
    @objc optional
    func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didReceiveTranscriptionSegments segments: [TranscriptionSegment])

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

    /// Fired when the first remote participant has subscribed to the localParticipant's track.
    @objc(room:localParticipant:remoteDidSubscribeTrack:) optional
    func room(_ room: Room, participant: LocalParticipant, remoteDidSubscribeTrack publication: LocalTrackPublication)

    /// A ``RemoteParticipant`` has un-published a ``RemoteTrack``.
    @objc(room:remoteParticipant:didUnpublishTrack:) optional
    func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication)

    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication)

    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication)

    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribeTrackWithSid trackSid: Track.Sid, error: LiveKitError)

    // MARK: - Data and Encryption

    /// Received data from from a user or server. `participant` will be nil if broadcasted from server.
    @objc optional
    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String)

    @objc optional
    func room(_ room: Room, trackPublication: TrackPublication, didUpdateE2EEState state: E2EEState)

    /// ``TrackPublication/isMuted`` has updated.
    @objc optional
    func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool)

    /// ``TrackPublication/streamState`` has updated.
    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, trackPublication: RemoteTrackPublication, didUpdateStreamState streamState: StreamState)

    /// ``RemoteTrackPublication/isSubscriptionAllowed`` has updated.
    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, trackPublication: RemoteTrackPublication, didUpdateIsSubscriptionAllowed isSubscriptionAllowed: Bool)

    // MARK: - Deprecated

    /// Renamed to ``RoomDelegate/room(_:didUpdateConnectionState:from:)``.
    @available(*, unavailable, renamed: "room(_:didUpdateConnectionState:from:)")
    @objc(room:didUpdateConnectionState:oldConnectionState:) optional
    func room(_ room: Room, didUpdate connectionState: ConnectionState, oldValue: ConnectionState)

    /// Renamed to ``RoomDelegate/roomDidConnect(_:)``.
    @available(*, unavailable, renamed: "roomDidConnect(_:)")
    @objc(room:didConnectIsReconnect:) optional
    func room(_ room: Room, didConnect isReconnect: Bool)

    /// Renamed to ``RoomDelegate/room(_:didFailToConnectWithError:)``.
    @available(*, unavailable, renamed: "room(_:didFailToConnectWithError:)")
    @objc optional
    func room(_ room: Room, didFailToConnect error: Error)

    /// Renamed to ``RoomDelegate/room(_:didDisconnectWithError:)``.
    @available(*, unavailable, renamed: "room(_:didDisconnectWithError:)")
    @objc optional
    func room(_ room: Room, didDisconnect error: Error?)

    /// Renamed to ``RoomDelegate/room(_:participantDidConnect:)``.
    @available(*, unavailable, renamed: "room(_:participantDidConnect:)")
    @objc(room:participantDidJoin:) optional
    func room(_ room: Room, participantDidJoin participant: RemoteParticipant)

    /// Renamed to ``RoomDelegate/room(_:participantDidDisconnect:)``.
    @available(*, unavailable, renamed: "room(_:participantDidDisconnect:)")
    @objc(room:participantDidLeave:) optional
    func room(_ room: Room, participantDidLeave participant: RemoteParticipant)

    /// Renamed to ``RoomDelegate/room(_:didUpdateSpeakingParticipants:)``.
    @available(*, unavailable, renamed: "room(_:didUpdateSpeakingParticipants:)")
    @objc(room:didUpdateSpeakers:) optional
    func room(_ room: Room, didUpdate speakers: [Participant])

    /// Renamed to ``RoomDelegate/room(_:didUpdateMetadata:)``.
    @available(*, unavailable, renamed: "room(_:didUpdateMetadata:)")
    @objc(room:didUpdateMetadata_:) optional
    func room(_ room: Room, didUpdate metadata: String?)

    /// Renamed to ``RoomDelegate/room(_:didUpdateIsRecording:)``.
    @available(*, unavailable, renamed: "room(_:didUpdateIsRecording:)")
    @objc(room:didUpdateIsRecording_:) optional
    func room(_ room: Room, didUpdate isRecording: Bool)

    /// Renamed to ``RoomDelegate/room(_:participant:didUpdateMetadata:)``.
    @available(*, unavailable, renamed: "room(_:participant:didUpdateMetadata:)")
    @objc(room:participant:didUpdateMetadata_:) optional
    func room(_ room: Room, participant: Participant, didUpdate metadata: String?)

    /// Renamed to ``RoomDelegate/room(_:participant:didUpdateConnectionQuality:)``.
    @available(*, unavailable, renamed: "room(_:participant:didUpdateConnectionQuality:)")
    @objc(room:participant:didUpdateConnectionQuality_:) optional
    func room(_ room: Room, participant: Participant, didUpdate connectionQuality: ConnectionQuality)

    /// Renamed to ``RoomDelegate/room(_:participant:trackPublication:didUpdateIsMuted:)``.
    @available(*, unavailable, renamed: "room(_:participant:trackPublication:didUpdateIsMuted:)")
    @objc(room:participant:publication:didUpdateMuted:) optional
    func room(_ room: Room, participant: Participant, didUpdate publication: TrackPublication, muted: Bool)

    /// Renamed to ``RoomDelegate/room(_:participant:didUpdatePermissions:)``.
    @available(*, unavailable, renamed: "room(_:participant:didUpdatePermissions:)")
    @objc(room:participant:didUpdatePermissions_:) optional
    func room(_ room: Room, participant: Participant, didUpdate permissions: ParticipantPermissions)

    /// Renamed to ``RoomDelegate/room(_:participant:trackPublication:didUpdateStreamState:)``.
    @available(*, unavailable, renamed: "room(_:participant:trackPublication:didUpdateStreamState:)")
    @objc(room:participant:publication:didUpdateStreamState:) optional
    func room(_ room: Room, participant: RemoteParticipant, didUpdate publication: RemoteTrackPublication, streamState: StreamState)

    /// Renamed to ``RoomDelegate/room(_:participant:didPublishTrack:)-418lx``.
    @available(*, unavailable, renamed: "room(_:participant:didPublishTrack:)")
    @objc(room:participant:didPublishPublication:) optional
    func room(_ room: Room, participant: RemoteParticipant, didPublish publication: RemoteTrackPublication)

    /// Renamed to ``RoomDelegate/room(_:participant:didUnpublishTrack:)-1jsz8``.
    @available(*, unavailable, renamed: "room(_:participant:didUnpublishTrack:)")
    @objc(room:participant:didUnpublishPublication:) optional
    func room(_ room: Room, participant: RemoteParticipant, didUnpublish publication: RemoteTrackPublication)

    /// Renamed to ``RoomDelegate/room(_:participant:didSubscribeTrack:)``.
    @available(*, unavailable, renamed: "room(_:participant:didSubscribeTrack:)")
    @objc(room:participant:didSubscribePublication:track:) optional
    func room(_ room: Room, participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track: Track)

    /// Renamed to ``RoomDelegate/room(_:participant:didFailToSubscribeTrack:withError:)``.
    @available(*, unavailable, renamed: "room(_:participant:didFailToSubscribeTrack:withError:)")
    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribe trackSid: String, error: Error)

    /// Renamed to ``RoomDelegate/room(_:participant:didUnsubscribeTrack:)``.
    @available(*, unavailable, renamed: "room(_:participant:didUnsubscribeTrack:)")
    @objc(room:publication:didUnsubscribePublication:track:) optional
    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribe publication: RemoteTrackPublication, track: Track)

    /// Renamed to ``RoomDelegate/room(_:participant:didReceiveData:forTopic:)``.
    @available(*, unavailable, renamed: "room(_:participant:didReceiveData:forTopic:)")
    @objc(room:participant:didReceiveData:) optional
    func room(_ room: Room, participant: RemoteParticipant?, didReceive data: Data)

    /// Renamed to ``RoomDelegate/room(_:participant:didReceiveData:forTopic:)``.
    @available(*, unavailable, renamed: "room(_:participant:didReceiveData:forTopic:)")
    @objc(room:participant:didReceiveData:topic:) optional
    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, topic: String)

    /// Renamed to ``RoomDelegate/room(_:participant:didPublishTrack:)-8xoph``.
    @available(*, unavailable, renamed: "room(_:participant:didPublishTrack:)")
    @objc(room:localParticipant:didPublishPublication:) optional
    func room(_ room: Room, localParticipant: LocalParticipant, didPublish publication: LocalTrackPublication)

    /// Renamed to ``RoomDelegate/room(_:participant:didUnpublishTrack:)-4r2nn``.
    @available(*, unavailable, renamed: "room(_:participant:didUnpublishTrack:)")
    @objc(room:localParticipant:didUnpublishPublication:) optional
    func room(_ room: Room, localParticipant: LocalParticipant, didUnpublish publication: LocalTrackPublication)

    /// Renamed to ``RoomDelegate/room(_:participant:didUpdatePermissions:)``.
    @available(*, unavailable, renamed: "room(_:participant:didUpdatePermissions:)")
    @objc optional
    func room(_ room: Room, participant: RemoteParticipant, didUpdate publication: RemoteTrackPublication, permission allowed: Bool)

    /// Renamed to ``RoomDelegate/room(_:trackPublication:didUpdateE2EEState:)``.
    @available(*, unavailable, renamed: "room(_:trackPublication:didUpdateE2EEState:)")
    @objc(room:publication:didUpdateE2EEState:) optional
    func room(_ room: Room, publication: TrackPublication, didUpdateE2EEState: E2EEState)
}
