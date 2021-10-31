import Foundation
import Logging
import Promises
import WebRTC

let logger = Logger(label: "io.livekit.ios")

/// The open source platform for real-time communication.
///
/// See [LiveKit's Online Docs](https://docs.livekit.io/) for more information.
///
/// Comments are written in [DocC](https://developer.apple.com/documentation/docc) compatible format.
/// With Xcode 13 and above you can build documentation right into your Xcode documentation viewer by chosing
/// **Product** >  **Build Documentation** from Xcode's menu.
///
/// Download the [Multiplatform SwiftUI Example](https://github.com/livekit/multiplatform-swiftui-example)
/// to try out the features.
public class LiveKit {

    static let queue = DispatchQueue(label: "lk_queue")

    public static func connect(
        _ url: String,
        _ token: String,
        options: ConnectOptions,
        delegate: RoomDelegate? = nil) -> Promise<Room> {

        let room = Room(delegate: delegate)
        return room.connect(url, token, options: options)
    }
}
