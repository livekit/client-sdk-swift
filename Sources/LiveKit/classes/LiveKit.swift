import Foundation
import Promises

public struct LiveKit {
    static let queue = DispatchQueue(label: "lk_queue")
    
    public static func connect(options: ConnectOptions, delegate: RoomDelegate? = nil) -> Room {
        let room = Room(options: options)
        room.delegate = delegate
        do {
            try room.connect().then { resp in
                print(resp)
            }
        } catch {
            print("Error: \(error)")
        }
        return room
    }
}
