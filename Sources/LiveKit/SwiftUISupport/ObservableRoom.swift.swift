import SwiftUI
import WebRTC
import OrderedCollections

open class ObservableRoom: ObservableObject {

    public let room: Room

    @Published public private(set) var participants = OrderedDictionary<Sid, ObservableParticipant>() {
        didSet {
            allParticipants = participants
            if let localParticipant = room.localParticipant {
                allParticipants.updateValue(ObservableParticipant(localParticipant),
                                            forKey: localParticipant.sid,
                                            insertingAt: 0)
            }
        }
    }

    @Published public private(set) var allParticipants = OrderedDictionary<Sid, ObservableParticipant>()

    @Published public var localVideo: LocalTrackPublication?
    @Published public var localAudio: LocalTrackPublication?
    @Published public var localScreen: LocalTrackPublication?

    public init(_ room: Room) {
        self.room = room
        room.add(delegate: self)

        if room.remoteParticipants.isEmpty {
            self.participants = [:]
        } else {
            // create initial participants
            for element in room.remoteParticipants {
                self.participants[element.key] = ObservableParticipant(element.value)
            }
        }
    }

    deinit {
        // cameraTrack?.stop()
        room.remove(delegate: self)
    }

}

extension ObservableRoom: RoomDelegate {

    public func room(_ room: Room,
                     participantDidJoin participant: RemoteParticipant) {
        DispatchQueue.main.async {
            self.participants[participant.sid] = ObservableParticipant(participant)
        }
    }

    public func room(_ room: Room,
                     participantDidLeave participant: RemoteParticipant) {
        DispatchQueue.main.async {
            self.participants.removeValue(forKey: participant.sid)
        }
    }
}
