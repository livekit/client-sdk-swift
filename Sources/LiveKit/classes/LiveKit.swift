import Foundation
import Logging
import Promises
import WebRTC

let logger = Logger(label: "io.livekit.ios")

public class LiveKit {
    static let queue = DispatchQueue(label: "lk_queue")
    static var audioConfigured: Bool = false

    public static func connect(options: ConnectOptions, delegate: RoomDelegate? = nil) -> Room {
        if !audioConfigured {
            do {
                try configureAudioSession()
            } catch {
                logger.error("could not configure audio: \(error)")
            }
        }
        let room = Room(options: options)
        room.delegate = delegate
        room.connect()
        return room
    }

    /// configures the current audio session.
    ///
    /// by default, LiveKit configures to .playback which doesn't require microphone permissions until when the user publishes their first track
    public static func configureAudioSession(category: AVAudioSession.Category = .playAndRecord,
                                             mode: AVAudioSession.Mode = .voiceChat,
                                             policy: AVAudioSession.RouteSharingPolicy = .default,
                                             options: AVAudioSession.CategoryOptions? = nil) throws
    {
        // for now, use playAndRecord since WebRTC does not support this yet.
//    public static func configureAudioSession(category: AVAudioSession.Category = .playback,
//                                             mode: AVAudioSession.Mode = .videoChat,
//                                             policy: AVAudioSession.RouteSharingPolicy = .longFormAudio,
//                                             options: AVAudioSession.CategoryOptions? = nil) throws {

        // validate policy
        var validPolicy = policy
        if category == .playAndRecord {
            if validPolicy == .longFormAudio {
                validPolicy = .default
            }
        }

        // validate options
        var validOptions: AVAudioSession.CategoryOptions
        if options != nil {
            validOptions = options!
        } else if category == .playAndRecord {
            validOptions = [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay, .defaultToSpeaker]
        } else {
            validOptions = []
        }

        if category != .playAndRecord {
            validOptions.remove(.defaultToSpeaker)
            validOptions.remove(.allowBluetooth)
            validOptions.remove(.allowAirPlay)
        }

        // WebRTC will initialize it according to what they need, so we have to change the default template
        let audioConfig = RTCAudioSessionConfiguration.webRTC()
        audioConfig.category = category.rawValue
        audioConfig.mode = mode.rawValue
        audioConfig.categoryOptions = validOptions
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(category, mode: mode, policy: validPolicy, options: validOptions)
        try audioSession.setActive(true)
        audioConfigured = true
    }

    public static func releaseAudioSession() throws {
        try AVAudioSession.sharedInstance().setActive(false)
        audioConfigured = false
    }
}
