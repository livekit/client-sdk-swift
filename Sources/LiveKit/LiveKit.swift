import Foundation
import Logging
import Promises
import WebRTC

let logger = Logger(label: "io.livekit.ios")

public typealias ConfigureAudioSession = (_ state: AudioTrack.TracksState,
                                          _ config: RTCAudioSessionConfiguration) -> Bool

public class LiveKit {

    static let queue = DispatchQueue(label: "lk_queue")
    //    static var audioConfigured: Bool = false

    /// Called when audio session configuration is required
    public static var onConfigureAudioSession: ConfigureAudioSession = defaultAudioSessionConfigureFunc

    public static func connect(options: ConnectOptions, delegate: RoomDelegate) -> Room {
        let room = Room(connectOptions: options, delegate: delegate)
        room.connect()
        return room
    }

    public static func defaultAudioSessionConfigureFunc(state: AudioTrack.TracksState,
                                                        config: RTCAudioSessionConfiguration) -> Bool {
        return true
    }

    //    /// configures the current audio session.
    //    ///
    //    /// by default, LiveKit configures to .playback which doesn't require microphone permissions until when the user publishes their first track
    //    public static func configureAudioSession(category: AVAudioSession.Category = .playback,
    //                                             mode: AVAudioSession.Mode = .spokenAudio,
    //                                             policy: AVAudioSession.RouteSharingPolicy = .longFormAudio,
    //                                             options: AVAudioSession.CategoryOptions? = nil) {
    //        // use serial queue to prevent mu
    //        queue.sync {
    //            // make sure we don't downgrade the session
    //            if audioConfigured {
    //                if category == .playback && AVAudioSession.sharedInstance().category == .playAndRecord {
    //                    return
    //                }
    //            }
    //            logger.info("configureAudioSession, category: \(category)")
    //            // validate policy
    //            var validPolicy = policy
    //            if category == .playAndRecord {
    //                if validPolicy == .longFormAudio {
    //                    validPolicy = .default
    //                }
    //            }
    //
    //            // validate options
    //            var validOptions: AVAudioSession.CategoryOptions
    //            if options != nil {
    //                validOptions = options!
    //            } else if category == .playAndRecord {
    //                validOptions = [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay, .defaultToSpeaker]
    //            } else {
    //                validOptions = []
    //            }
    //
    //            if category != .playAndRecord {
    //                validOptions.remove(.defaultToSpeaker)
    //                validOptions.remove(.allowBluetooth)
    //                validOptions.remove(.allowAirPlay)
    //            }
    //
    //            // WebRTC will initialize it according to what they need, so we have to change the default template
    //            let audioConfig = RTCAudioSessionConfiguration.webRTC()
    //            audioConfig.category = category.rawValue
    //            audioConfig.mode = mode.rawValue
    //            audioConfig.categoryOptions = validOptions
    //            let audioSession = AVAudioSession.sharedInstance()
    //            do {
    //                try audioSession.setCategory(category, mode: mode, policy: validPolicy, options: validOptions)
    //                try audioSession.setActive(true)
    //                audioConfigured = true
    //            } catch {
    //                logger.error("Could not configure session: \(error)")
    //            }
    //        }
    //    }

    //    public static func releaseAudioSession() {
    //        logger.info("releasing audioSession")
    //        queue.sync {
    //            do {
    //                try AVAudioSession.sharedInstance().setActive(false)
    //                audioConfigured = false
    //            } catch {
    //                logger.error("could not release session: \(error)")
    //            }
    //        }
    //    }
}
