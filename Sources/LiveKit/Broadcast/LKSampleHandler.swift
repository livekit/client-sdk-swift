import ReplayKit
import WebRTC
import Promises
import os.log

open class LKSampleHandler: RPBroadcastSampleHandler {

    lazy var room = Room()
    var bufferTrack: LocalVideoTrack?
    var publication: LocalTrackPublication?
    
    internal let broadcastLogger = OSLog(subsystem: "io.livekit.screen-broadcaster",
                       category: "Broadcaster")
    
    /**
     @abstract
     The App Group ID that the app and broadcast extension are setup with.
     */
    open func appGroupIdentifier() -> String {
        preconditionFailure("This method must be overriden with the app group identifier.")
    }
    
    /**
     The target key to look for the URL in the UserDefaults. Defaults to "livekit_url".
     */
    open func urlKey() -> String {
        return "livekit_url"
    }
    
    /**
     The target key to look for the token in the UserDefaults. Defaults to "livekit_token".
     */
    open func tokenKey() -> String {
        return "livekit_token"
    }

    override open func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {

        os_log("broadcast started", log: broadcastLogger, type: .debug)

        if let ud = UserDefaults(suiteName: appGroupIdentifier()),
           let url = ud.string(forKey: urlKey()),
           let token = ud.string(forKey: tokenKey()) {

            let connectOptions = ConnectOptions(
                // do not subscribe since this is for publish only
                autoSubscribe: false,
                publishOnlyMode: "screen_share"
            )

            let roomOptions = RoomOptions(
                defaultVideoPublishOptions: VideoPublishOptions(
                    simulcast: false
                )
            )

            room.connect(url,
                         token,
                         connectOptions: connectOptions,
                         roomOptions: roomOptions).then { (room) -> Promise<LocalTrackPublication> in
                            self.bufferTrack = LocalVideoTrack.createBufferTrack()
                            return room.localParticipant!.publishVideoTrack(track: self.bufferTrack!)
                         }.then { publication in
                            self.publication = publication
                         }
        } else {
            os_log("broadcast connect failed", log: broadcastLogger, type: .debug)
        }
    }

    override open func broadcastPaused() {
        // User has requested to pause the broadcast. Samples will stop being delivered.
        os_log("broadcast paused", log: broadcastLogger, type: .debug)
    }

    override open func broadcastResumed() {
        // User has requested to resume the broadcast. Samples delivery will resume.
        os_log("broadcast resumed", log: broadcastLogger, type: .debug)
    }

    override open func broadcastFinished() {
        // User has requested to finish the broadcast.
        os_log("broadcast finished", log: broadcastLogger, type: .debug)

        room.disconnect()
    }

    override open func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {

        // os_log("processSampleBuffer", log: logger, type: .debug)

        switch sampleBufferType {
        case RPSampleBufferType.video:

            guard let capturer = bufferTrack?.capturer as? BufferCapturer else {
                return
            }

            capturer.capture(sampleBuffer)

        default: break
        }
    }
}
