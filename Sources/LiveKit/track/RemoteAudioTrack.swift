import WebRTC

class RemoteAudioTrack: AudioTrack {

    override func start() {
        super.start()
        super.enable()
    }

    override func stop() {
        super.stop()
        super.disable()
    }
}
