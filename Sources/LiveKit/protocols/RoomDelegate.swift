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
    func room(_ room: Room, didUpdate connectionState: ConnectionState)

    /// When a RemoteParticipant joins after the local participant.
    /// It will not emit events for participants that are already in the room
    func room(_ room: Room, participantDidJoin participant: RemoteParticipant)

    /// When a RemoteParticipant leaves after the local participant has joined.
    func room(_ room: Room, participantDidLeave participant: RemoteParticipant)

    /// When a reconnect attempt had been successful
    //    func didReconnect(room: Room)

    /// Active speakers changed.
    ///
    /// List of speakers are ordered by their audio level. loudest speakers first. This will include the LocalParticipant too.
    func room(_ room: Room, didUpdate speakers: [Participant])

    /* All Participants */

    /// Participant's metadata has been changed
    func room(_ room: Room, participant: Participant, didUpdate metadata: String?)

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
    func room(_ room: Room, participant: Participant, didUpdate track: TrackPublication, muted: Bool)

    /* Remote Participant */

    /// When a new track is published to room after the local participant has joined.
    ///
    /// It will not fire for tracks that are already published
    func room(_ room: Room, participant: RemoteParticipant, didPublish remoteTrack: RemoteTrackPublication)

    /// A RemoteParticipant has unpublished a track
    //    func didUnpublishRemoteTrack(publication: RemoteTrackPublication, particpant: RemoteParticipant)
    func room(_ room: Room, participant: RemoteParticipant, didUnpublish remoteTrack: RemoteTrackPublication)

    /// The LocalParticipant has subscribed to a new track.
    ///
    /// This event will always fire as long as new tracks are ready for use.
    //    func didSubscribe(track: Track, publication: RemoteTrackPublication, participant: RemoteParticipant)
    func room(_ room: Room, participant: RemoteParticipant, didSubscribe trackPublication: RemoteTrackPublication, track: Track)

    /// Could not subscribe to a track.
    ///
    /// This is an error state, the subscription can be retried
    //    func didFailToSubscribe(sid: String, error: Error, participant: RemoteParticipant)
    func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribe trackSid: String, error: Error)

    /// A subscribed track is no longer available.
    ///
    /// Clients should listen to this event and handle cleanup
    //    func didUnsubscribe(track: Track, publication: RemoteTrackPublication, participant: RemoteParticipant)
    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribe trackPublication: RemoteTrackPublication)

    /// Data was received from a RemoteParticipant
    func room(_ room: Room, participant: RemoteParticipant, didReceive data: Data)
}

public extension RoomDelegate {
    func room(_ room: Room, didConnect isReconnect: Bool) {}
    func room(_ room: Room, didFailToConnect error: Error) {}
    func room(_ room: Room, didDisconnect error: Error?) {}
    func room(_ room: Room, didUpdate connectionState: ConnectionState) {}
    func room(_ room: Room, didUpdate speakers: [Participant]) {}
    func room(_ room: Room, participantDidJoin participant: RemoteParticipant) {}
    func room(_ room: Room, participantDidLeave participant: RemoteParticipant) {}
    func room(_ room: Room, participant: Participant, didUpdate metadata: String?) {}
    func room(_ room: Room, participant: Participant, didUpdate track: TrackPublication, muted: Bool) {}
    func room(_ room: Room, participant: RemoteParticipant, didPublish remoteTrack: RemoteTrackPublication) {}
    func room(_ room: Room, participant: RemoteParticipant, didUnpublish remoteTrack: RemoteTrackPublication) {}
    func room(_ room: Room, participant: RemoteParticipant, didSubscribe trackPublication: RemoteTrackPublication, track: Track) {}
    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribe trackPublication: RemoteTrackPublication) {}
    func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribe trackSid: String, error: Error) {}
    func room(_ room: Room, participant: RemoteParticipant, didReceive data: Data) {}
}
