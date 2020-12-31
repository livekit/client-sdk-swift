import Foundation
import Promises

public struct LiveKit {
    static let queue = DispatchQueue(label: "lk_queue")
    
    public static func connect(options: ConnectOptions, delegate: RoomDelegate? = nil) -> Promise<Room> {
        let promise = options.config.roomId != nil ? Room.join(options: options) : Room.create(options: options)
        promise.then { room in
            do {
                room.delegate = delegate
                try room.connect().then { resp in
                    print(resp)
                }
            } catch {
                print("Error: \(error)")
            }
        }
        return promise
    }
}
