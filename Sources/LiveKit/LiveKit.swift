import Foundation
import Logging
import Promises
import WebRTC

let logger = Logger(label: "io.livekit.ios")

#if !os(macOS)
public typealias ConfigureAudioSession = (_ state: AudioTrack.TracksState,
                                          _ config: RTCAudioSessionConfiguration) -> Bool
#endif

public class LiveKit {

    static let queue = DispatchQueue(label: "lk_queue")

    public static func connect(options: ConnectOptions, delegate: RoomDelegate? = nil) -> Promise<Room> {
        let room = Room(connectOptions: options, delegate: delegate)
        return room.connect()
    }
}
