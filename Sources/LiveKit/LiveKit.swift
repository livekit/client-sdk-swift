import Foundation
import Logging
import Promises
import WebRTC

let logger = Logger(label: "io.livekit.ios")

public class LiveKit {

    static let queue = DispatchQueue(label: "lk_queue")

    public static func connect(options: ConnectOptions, delegate: RoomDelegate) -> Promise<Room> {
        let room = Room(connectOptions: options, delegate: delegate)
        return room.connect()
    }
}
