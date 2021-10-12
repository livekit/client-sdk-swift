import Foundation

/// delegate methods for a participant.
///
/// You can set `Participant.delegate` on each participant. All delegate methods are optional
/// To ensure each participant's delegate is registered, you can look through `Room.localParticipant` and `Room.remoteParticipants` on connect
/// and register it on new participants inside `RoomDelegate.participantDidConnect`
public protocol ParticipantDelegate {
    // all participants
    /// Participant's metadata has been changed
    func participant(_ participant: Participant, didUpdate metadata: String?)

    /// The isSpeaking status of the participant has changed
    func participant(_ participant: Participant, didUpdate speaking: Bool)

    /// The participant was muted.
    ///
    /// For the local participant, the callback will be called if setMute was called on LocalTrackPublication,
    /// or if the server has requested the participant to be muted
    func participant(_ participant: Participant, didUpdate trackPublication: TrackPublication, muted: Bool)

    /// The participant was unmuted.
    ///
    /// For the local participant, the callback will be called if setMute was called on LocalTrackPublication,
    /// or if the server has requested the participant to be unmuted
    // func didUnmute(publication: TrackPublication, participant: Participant)

    // remote participants
    /// When a new track is published to room after the local participant has joined.
    ///
    /// It will not fire for tracks that are already published
    func participant(_ participant: RemoteParticipant, didPublish trackPublication: RemoteTrackPublication)

    /// A RemoteParticipant has unpublished a track
    func participant(_ participant: RemoteParticipant, didUnpublish trackPublication: RemoteTrackPublication)

    /// The LocalParticipant has subscribed to a new track.
    ///
    /// This event will always fire as long as new tracks are ready for use.
    func participant(_ participant: RemoteParticipant, didSubscribe trackPublication: RemoteTrackPublication, track: Track)

    /// Could not subscribe to a track.
    ///
    /// This is an error state, the subscription can be retried
    func participant(_ participant: RemoteParticipant, didFailToSubscribe trackSid: String, error: Error)

    /// A subscribed track is no longer available.
    ///
    /// Clients should listen to this event and handle cleanup
    func participant(_ participant: RemoteParticipant, didUnsubscribe trackPublication: RemoteTrackPublication, track: Track)

    /// Data was received from a RemoteParticipant
    func participant(_ participant: RemoteParticipant, didReceive data: Data)
}

public extension ParticipantDelegate {
    func participant(_ participant: Participant, didUpdate metadata: String?) {}
    func participant(_ participant: Participant, didUpdate speaking: Bool) {}
    func participant(_ participant: Participant, didUpdate trackPublication: TrackPublication, muted: Bool) {}
    func participant(_ participant: RemoteParticipant, didPublish trackPublication: RemoteTrackPublication) {}
    func participant(_ participant: RemoteParticipant, didUnpublish trackPublication: RemoteTrackPublication) {}
    func participant(_ participant: RemoteParticipant, didSubscribe trackPublication: RemoteTrackPublication, track: Track) {}
    func participant(_ participant: RemoteParticipant, didUnsubscribe trackPublication: RemoteTrackPublication, track: Track) {}
    func participant(_ participant: RemoteParticipant, didFailToSubscribe trackSid: String, error: Error) {}
    func participant(_ participant: RemoteParticipant, didReceive data: Data) {}
}
