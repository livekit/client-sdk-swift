import Foundation
import Logging
import Promises
import WebRTC

let logger = Logger(label: "io.livekit.ios")

public typealias ConfigureAudioSession = (_ state: AudioTrack.TracksState,
                                          _ config: RTCAudioSessionConfiguration) -> Bool

public class LiveKit {

    static let queue = DispatchQueue(label: "lk_queue")

    /// Called when audio session configuration is required
    public static var onConfigureAudioSession: ConfigureAudioSession = defaultAudioSessionConfigureFunc

    public static func connect(options: ConnectOptions, delegate: RoomDelegate) -> Room {
        let room = Room(connectOptions: options, delegate: delegate)
        room.connect()
        return room
    }

    public static func defaultAudioSessionConfigureFunc(state: AudioTrack.TracksState,
                                                        config: RTCAudioSessionConfiguration) -> Bool {

        switch state {
        case .remoteOnly:
            config.category = AVAudioSession.Category.playback.rawValue
            config.mode = AVAudioSession.Mode.spokenAudio.rawValue
        case .localOnly, .localAndRemote:
            config.category = AVAudioSession.Category.playAndRecord.rawValue
            config.mode = AVAudioSession.Mode.videoChat.rawValue
        default:
            config.category = AVAudioSession.Category.soloAmbient.rawValue
            config.mode = AVAudioSession.Mode.default.rawValue
        }

        return true
    }
}
