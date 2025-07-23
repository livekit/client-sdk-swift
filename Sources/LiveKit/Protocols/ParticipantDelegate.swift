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

/// Delegate methods for a participant.
///
/// Since ``Participant`` inherits from ``MulticastDelegate``,
/// you can call `add(delegate:)` on ``Participant`` to add as many delegates as you need.
/// All delegate methods are optional.
///
/// To ensure each participant's delegate is registered, you can look through ``Room/localParticipant`` and ``Room/remoteParticipants`` on connect
/// and register it on new participants inside ``RoomDelegate/room(_:participantDidJoin:)``
@objc
public protocol ParticipantDelegate: AnyObject, Sendable {
    // MARK: - Participant

    /// A ``Participant``'s metadata has updated.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc optional
    func participant(_ participant: Participant, didUpdateMetadata metadata: String?)

    /// A ``Participant``'s name has updated.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc optional
    func participant(_ participant: Participant, didUpdateName name: String)

    /// The isSpeaking status of a ``Participant`` has changed.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc optional
    func participant(_ participant: Participant, didUpdateIsSpeaking isSpeaking: Bool)

    /// The state of a ``Participant`` has updated.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc optional
    func participant(_ participant: Participant, didUpdateState state: ParticipantState)

    /// The connection quality of a ``Participant`` has updated.
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc optional
    func participant(_ participant: Participant, didUpdateConnectionQuality connectionQuality: ConnectionQuality)

    @objc optional
    func participant(_ participant: Participant, didUpdatePermissions permissions: ParticipantPermissions)

    @objc optional
    func participant(_ participant: Participant, didUpdateAttributes attributes: [String: String])

    // MARK: - TrackPublication

    /// `muted` state has updated for the ``Participant``'s ``TrackPublication``.
    ///
    /// For the ``LocalParticipant``, the delegate method will be called if setMute was called on ``LocalTrackPublication``,
    /// or if the server has requested the participant to be muted.
    ///
    /// `participant` Can be a ``LocalParticipant`` or a ``RemoteParticipant``.
    @objc optional
    func participant(_ participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool)

    /// Received transcription segments.
    @objc optional
    func participant(_ participant: Participant, trackPublication: TrackPublication, didReceiveTranscriptionSegments segments: [TranscriptionSegment])

    // MARK: - LocalTrackPublication

    /// The ``LocalParticipant`` has published a ``LocalTrackPublication``.
    @objc(localParticipant:didPublishTrack:) optional
    func participant(_ participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication)

    /// The ``LocalParticipant`` has unpublished a ``LocalTrackPublication``.
    @objc(localParticipant:didUnpublishTrack:) optional
    func participant(_ participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication)

    /// Fired when the first remote participant has subscribed to the localParticipant's track.
    @objc(localParticipant:remoteDidSubscribeTrack:) optional
    func participant(_ participant: LocalParticipant, remoteDidSubscribeTrack publication: LocalTrackPublication)

    // MARK: - RemoteTrackPublication

    /// When a new ``RemoteTrackPublication`` is published to ``Room`` after the ``LocalParticipant`` has joined.
    ///
    /// This delegate method will not be called for tracks that are already published.
    @objc(remoteParticipant:didPublishTrack:) optional
    func participant(_ participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication)

    /// The ``RemoteParticipant`` has unpublished a ``RemoteTrackPublication``.
    @objc(remoteParticipant:didUnpublishTrack:) optional
    func participant(_ participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication)

    /// The ``LocalParticipant`` has subscribed to a new ``RemoteTrackPublication``.
    ///
    /// This event will always fire as long as new tracks are ready for use.
    @objc optional
    func participant(_ participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication)

    /// Unsubscribed from a ``RemoteTrackPublication`` and  is no longer available.
    ///
    /// Clients should listen to this event and handle cleanup.
    @objc optional
    func participant(_ participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication)

    /// Could not subscribe to a track.
    ///
    /// This is an error state, the subscription can be retried.
    @objc optional
    func participant(_ participant: RemoteParticipant, didFailToSubscribeTrackWithSid trackSid: Track.Sid, error: LiveKitError)

    /// ``TrackPublication/streamState`` has updated for the ``RemoteTrackPublication``.
    @objc optional
    func participant(_ participant: RemoteParticipant, trackPublication: RemoteTrackPublication, didUpdateStreamState streamState: StreamState)

    /// ``RemoteTrackPublication/isSubscriptionAllowed`` has updated for the ``RemoteTrackPublication``.
    @objc optional
    func participant(_ participant: RemoteParticipant, trackPublication: RemoteTrackPublication, didUpdateIsSubscriptionAllowed isSubscriptionAllowed: Bool)

    // MARK: - Data

    /// Data was received from a ``RemoteParticipant``.
    @objc optional
    func participant(_ participant: RemoteParticipant, didReceiveData data: Data, forTopic topic: String)

    // MARK: - Deprecated

    /// Renamed to ``ParticipantDelegate/participant(_:didUpdateMetadata:)``.
    @available(*, unavailable, renamed: "participant(_:didUpdateMetadata:)")
    @objc(participant:didUpdateMetadata_:) optional
    func participant(_ participant: Participant, didUpdate metadata: String?)

    // Renamed to ``ParticipantDelegate/participant(_:didUpdateName:)``.
    // @available(*, unavailable, renamed: "participant(_:didUpdateName:)")
    // @objc(participant:didUpdateName_:) optional
    // func participant(_ participant: Participant, didUpdateName: String)

    /// Renamed to ``ParticipantDelegate/participant(_:didUpdateIsSpeaking:)``.
    @available(*, unavailable, renamed: "participant(_:didUpdateIsSpeaking:)")
    @objc(participant:didUpdateSpeaking:) optional
    func participant(_ participant: Participant, didUpdate speaking: Bool)

    /// Renamed to ``ParticipantDelegate/participant(_:didUpdateConnectionQuality:)``.
    @available(*, unavailable, renamed: "participant(_:didUpdateConnectionQuality:)")
    @objc(participant:didUpdateConnectionQuality_:) optional
    func participant(_ participant: Participant, didUpdate connectionQuality: ConnectionQuality)

    /// Renamed to ``ParticipantDelegate/participant(_:trackPublication:didUpdateIsMuted:)``.
    @available(*, unavailable, renamed: "participant(_:trackPublication:didUpdateIsMuted:)")
    @objc(participant:publication:didUpdateMuted:) optional
    func participant(_ participant: Participant, didUpdate publication: TrackPublication, muted: Bool)

    /// Renamed to ``ParticipantDelegate/participant(_:didUpdatePermissions:)``.
    @available(*, unavailable, renamed: "participant(_:didUpdatePermissions:)")
    @objc(participant:didUpdatePermissions_:) optional
    func participant(_ participant: Participant, didUpdate permissions: ParticipantPermissions)

    /// Renamed to ``ParticipantDelegate/participant(_:trackPublication:didUpdateStreamState:)``.
    @available(*, unavailable, renamed: "participant(_:trackPublication:didUpdateStreamState:)")
    @objc(participant:publication:didUpdateStreamState:) optional
    func participant(_ participant: RemoteParticipant, didUpdate publication: RemoteTrackPublication, streamState: StreamState)

    /// Renamed to ``ParticipantDelegate/participant(_:trackPublication:didUpdateIsSubscriptionAllowed:)``.
    @available(*, unavailable, renamed: "participant(_:trackPublication:didUpdateIsSubscriptionAllowed:)")
    @objc(participant:publication:didUpdateCanSubscribe:) optional
    func participant(_ participant: RemoteParticipant, didUpdate publication: RemoteTrackPublication, permission allowed: Bool)

    /// Renamed to ``ParticipantDelegate/participant(_:didPublishTrack:)-8e9iw``.
    @available(*, unavailable, renamed: "participant(_:didPublishTrack:)")
    @objc(remoteParticipant:didPublish:) optional
    func participant(_ participant: RemoteParticipant, didPublish publication: RemoteTrackPublication)

    /// Renamed to ``ParticipantDelegate/participant(_:didUnpublishTrack:)-1roup``.
    @available(*, unavailable, renamed: "participant(_:didUnpublishTrack:)")
    @objc(remoteParticipant:didUnpublish:) optional
    func participant(_ participant: RemoteParticipant, didUnpublish publication: RemoteTrackPublication)

    /// Renamed to ``ParticipantDelegate/participant(_:didPublishTrack:)-7emm``.
    @available(*, unavailable, renamed: "participant(_:didPublishTrack:)")
    @objc(localParticipant:didPublish:) optional
    func localParticipant(_ participant: LocalParticipant, didPublish publication: LocalTrackPublication)

    /// Renamed to ``ParticipantDelegate/participant(_:didUnpublishTrack:)-4pv3r``.
    @available(*, unavailable, renamed: "participant(_:didUnpublishTrack:)")
    @objc(localParticipant:didUnpublish:) optional
    func localParticipant(_ participant: LocalParticipant, didUnpublish publication: LocalTrackPublication)

    /// Renamed to ``ParticipantDelegate/participant(_:didSubscribeTrack:)``.
    @available(*, unavailable, renamed: "participant(_:didSubscribeTrack:)")
    @objc(participant:didSubscribe:track:) optional
    func participant(_ participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track: Track)

    /// Renamed to ``ParticipantDelegate/participant(_:didFailToSubscribeTrackWithSid:error:)``.
    @available(*, unavailable, renamed: "participant(_:didFailToSubscribeTrackWithSid:error:)")
    func participant(_ participant: RemoteParticipant, didFailToSubscribe trackSid: String, error: Error)

    /// Renamed to ``ParticipantDelegate/participant(_:didUnsubscribeTrack:)``.
    @available(*, unavailable, renamed: "participant(_:didUnsubscribeTrack:)")
    @objc(participant:didUnsubscribePublication:track:) optional
    func participant(_ participant: RemoteParticipant, didUnsubscribe publication: RemoteTrackPublication, track: Track)

    /// Renamed to ``ParticipantDelegate/participant(_:didReceiveData:forTopic:)``.
    @available(*, unavailable, renamed: "participant(_:didReceiveData:forTopic:)")
    @objc(participant:didReceiveData:) optional
    func participant(_ participant: RemoteParticipant, didReceive data: Data)

    /// Renamed to ``ParticipantDelegate/participant(_:didReceiveData:forTopic:)``.
    @available(*, unavailable, renamed: "participant(_:didReceiveData:forTopic:)")
    @objc(participant:didReceiveData:topic:) optional
    func participant(_ participant: RemoteParticipant, didReceiveData data: Data, topic: String)
}
