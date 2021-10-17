import Foundation
import Logging
import Promises
import WebRTC

let logger = Logger(label: "io.livekit.ios")


public typealias ConfigureAudioSession = (_ newState: AudioTrack.TracksState,
                                          _ oldState: AudioTrack.TracksState,
                                          _ config: RTCAudioSessionConfiguration) -> Bool?

public class LiveKit {

    static let queue = DispatchQueue(label: "lk_queue")

    /// Called when audio session configuration is required by the SDK. By default `defaultAudioSessionConfigureFunc` is used and
    /// will be handled automatically.
    public static var onConfigureAudioSession: ConfigureAudioSession? = defaultAudioSessionConfigureFunc

    public static func connect(options: ConnectOptions, delegate: RoomDelegate) -> Promise<Room> {
        let room = Room(connectOptions: options, delegate: delegate)
        return room.connect()
    }

    public static func defaultAudioSessionConfigureFunc(newState: AudioTrack.TracksState,
                                                        oldState: AudioTrack.TracksState,
                                                        config: RTCAudioSessionConfiguration) -> Bool? {

        switch newState {
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

        var setActive: Bool?
        if newState != .none, oldState == .none {
            // activate audio session when there is any local/remote audio track
            setActive = true
        } else if newState == .none, oldState != .none {
            // deactivate audio session when there are no more local/remote audio tracks
            setActive = false
        }

        return setActive
    }
}
