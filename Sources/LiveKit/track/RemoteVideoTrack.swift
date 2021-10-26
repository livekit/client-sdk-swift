import WebRTC

class RemoteVideoTrack: VideoTrack {

    override func start() {
        super.start()
        super.enable()
    }

    override func stop() {
        super.stop()
        super.disable()
    }
}
