import Foundation
import Promises
import Logging
import WebRTC

let logger = Logger(label: "io.livekit.ios")

public struct LiveKit {
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
    
    public static func configureAudioSession(category: AVAudioSession.Category = .playAndRecord,
                                      mode: AVAudioSession.Mode = .voiceChat,
                                      options: AVAudioSession.CategoryOptions = .mixWithOthers) throws {
        audioConfigured = true
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        defer { audioSession.unlockForConfiguration() }
        try audioSession.setCategory(category.rawValue, with: options)
        try audioSession.setMode(mode.rawValue)
    }
}
