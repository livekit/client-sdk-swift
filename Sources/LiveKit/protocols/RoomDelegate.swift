import Foundation

/// RoomDelegate receives room events as well as participant events.
///
/// The only two required delegates are `participantDidConnect` and `participantDidDisconnect`
public protocol RoomDelegate {
    /// Successfully connected to the room
    func didConnect(room: Room)

    /// Could not connect to the room
    func didFailToConnect(room: Room, error: Error)

    /// Client disconnected from the room unexpectedly
    func didDisconnect(room: Room, error: Error?)

    /// When a RemoteParticipant joins after the local participant.
    /// It will not emit events for participants that are already in the room
    func participantDidConnect(room: Room, participant: RemoteParticipant)

    /// When a RemoteParticipant leaves after the local participant has joined.
    func participantDidDisconnect(room: Room, participant: RemoteParticipant)

    /// When a network change has been detected and LiveKit attempts to reconnect to the room
    /// When reconnect attempts succeed, the room state will be kept, including tracks that are subscribed/published
    func isReconnecting(room: Room)

    /// When a reconnect attempt had been successful
    func didReconnect(room: Room)

    /// Active speakers changed.
    ///
    /// List of speakers are ordered by their audio level. loudest speakers first. This will include the LocalParticipant too.
    func activeSpeakersDidChange(speakers: [Participant], room: Room)

    /* All Participants */

    /// Participant's metadata has been changed
    func metadataDidChange(participant: Participant)

    /// The participant was muted.
    ///
    /// For the local participant, the callback will be called if setMute was called on the local participant,
    /// or if the server has requested the participant to be muted
    func didMute(publication: TrackPublication, participant: Participant)

    /// The participant was unmuted.
    ///
    /// For the local participant, the callback will be called if setMute was called on the local participant,
    /// or if the server has requested the participant to be unmuted
    func didUnmute(publication: TrackPublication, participant: Participant)

    /* Remote Participant */

    /// When a new track is published to room after the local participant has joined.
    ///
    /// It will not fire for tracks that are already published
    func didPublishRemoteTrack(publication: RemoteTrackPublication, participant: RemoteParticipant)

    /// A RemoteParticipant has unpublished a track
    func didUnpublishRemoteTrack(publication: RemoteTrackPublication, particpant: RemoteParticipant)

    /// The LocalParticipant has subscribed to a new track.
    ///
    /// This event will always fire as long as new tracks are ready for use.
    func didSubscribe(track: Track, publication: RemoteTrackPublication, participant: RemoteParticipant)

    /// Could not subscribe to a track.
    ///
    /// This is an error state, the subscription can be retried
    func didFailToSubscribe(sid: String, error: Error, participant: RemoteParticipant)

    /// A subscribed track is no longer available.
    ///
    /// Clients should listen to this event and handle cleanup
    func didUnsubscribe(track: Track, publication: RemoteTrackPublication, participant: RemoteParticipant)

    /// Data was received from a RemoteParticipant
    func didReceive(data: Data, participant: RemoteParticipant)
}

public extension RoomDelegate {
    func participantDidConnect(room _: Room, participant _: RemoteParticipant) {}
    func participantDidDisconnect(room _: Room, participant _: RemoteParticipant) {}
    func isReconnecting(room _: Room) {}
    func didReconnect(room _: Room) {}
    func activeSpeakersDidChange(speakers _: [Participant], room _: Room) {}
    func metadataDidChange(participant _: Participant) {}
    func didMute(publication _: TrackPublication, participant _: Participant) {}
    func didUnmute(publication _: TrackPublication, participant _: Participant) {}
    func didPublishRemoteTrack(publication _: RemoteTrackPublication, participant _: RemoteParticipant) {}
    func didUnpublishRemoteTrack(publication _: RemoteTrackPublication, particpant _: RemoteParticipant) {}
    func didSubscribe(track _: Track, publication _: RemoteTrackPublication, participant _: RemoteParticipant) {}
    func didFailToSubscribe(sid _: String, error _: Error, participant _: RemoteParticipant) {}
    func didUnsubscribe(track _: Track, publication _: RemoteTrackPublication, participant _: RemoteParticipant) {}
    func didReceive(data _: Data, participant _: RemoteParticipant) {}
}
