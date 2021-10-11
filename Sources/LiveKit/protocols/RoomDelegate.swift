import Foundation

/// RoomDelegate receives room events as well as participant events.
///
/// The only two required delegates are `participantDidConnect` and `participantDidDisconnect`
public protocol RoomDelegate {
    /// Successfully connected to the room
    func room(_ room: Room, didConnect isReconnect: Bool)

    /// Could not connect to the room
    func room(_ room: Room, didFailToConnect error: Error)

    /// Client disconnected from the room unexpectedly
    func room(_ room: Room, didDisconnect error: Error?)

    /// When a network change has been detected and LiveKit attempts to reconnect to the room
    /// When reconnect attempts succeed, the room state will be kept, including tracks that are subscribed/published
    func roomIsReconnecting(_ room: Room)

    /// When a RemoteParticipant joins after the local participant.
    /// It will not emit events for participants that are already in the room
    func room(_ room: Room, participantDidConnect participant: RemoteParticipant)

    /// When a RemoteParticipant leaves after the local participant has joined.
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant)

    /// When a reconnect attempt had been successful
//    func didReconnect(room: Room)

    /// Active speakers changed.
    ///
    /// List of speakers are ordered by their audio level. loudest speakers first. This will include the LocalParticipant too.
    func room(_ room: Room, didUpdate speakers: [Participant])

    /* All Participants */

    /// Participant's metadata has been changed
    func room(_ room: Room, participantDidUpdate participant: Participant, metadata: String?)

    /// The participant was muted.
    ///
    /// For the local participant, the callback will be called if setMute was called on the local participant,
    /// or if the server has requested the participant to be muted
//    func didMute(publication: TrackPublication, participant: Participant)

    /// The participant was unmuted.
    ///
    /// For the local participant, the callback will be called if setMute was called on the local participant,
    /// or if the server has requested the participant to be unmuted
//    func didUnmute(publication: TrackPublication, participant: Participant)
    func room(_ room: Room, participantDidUpdate participant: Participant, track: TrackPublication, muted: Bool)

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
    func room(_ room: Room, didConnect isReconnect: Bool) {}
    func room(_ room: Room, didFailToConnect error: Error) {}
    func room(_ room: Room, didDisconnect error: Error?) {}
    func roomIsReconnecting(_ room: Room) {}
    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {}
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {}

//    func didReconnect(room _: Room) {}
    func room(_ room: Room, didUpdate speakers: [Participant]) {}
    func room(_ room: Room, participantDidUpdate participant: Participant, metadata: String?) {}

//    func didMute(publication _: TrackPublication, participant _: Participant) {}
//    func didUnmute(publication _: TrackPublication, participant _: Participant) {}
    func room(_ room: Room, participantDidUpdate participant: Participant, track: TrackPublication, muted: Bool) {}

    func didPublishRemoteTrack(publication _: RemoteTrackPublication, participant _: RemoteParticipant) {}
    func didUnpublishRemoteTrack(publication _: RemoteTrackPublication, particpant _: RemoteParticipant) {}
    func didSubscribe(track _: Track, publication _: RemoteTrackPublication, participant _: RemoteParticipant) {}
    func didFailToSubscribe(sid _: String, error _: Error, participant _: RemoteParticipant) {}
    func didUnsubscribe(track _: Track, publication _: RemoteTrackPublication, participant _: RemoteParticipant) {}
    func didReceive(data _: Data, participant _: RemoteParticipant) {}
}
