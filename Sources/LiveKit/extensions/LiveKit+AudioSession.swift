import WebRTC

/// Function type for `LiveKit.onShouldConfigureAudioSession`.
/// - Parameters:
///   - newState: The new state of audio tracks
///   - oldState: The previous state of audio tracks
public typealias ShouldConfigureAudioSessionFunc = (_ newState: AudioTrack.TracksState,
                                                    _ oldState: AudioTrack.TracksState) -> Void

extension LiveKit {

    #if !os(macOS)
    /// Called when audio session configuration is suggested by the SDK.
    ///
    /// By default, ``defaultShouldConfigureAudioSessionFunc(newState:oldState:)`` is used and this
    /// will be handled automatically.
    ///
    /// To change the default behavior, set this to your own ``ShouldConfigureAudioSessionFunc`` function and call
    /// ``configureAudioSession(_:setActive:)`` with your own configuration.
    ///
    /// View ``defaultShouldConfigureAudioSessionFunc(newState:oldState:)`` for the default implementation.
    ///
    public static var onShouldConfigureAudioSession: ShouldConfigureAudioSessionFunc = defaultShouldConfigureAudioSessionFunc

    /// Configure the `RTCAudioSession` of `WebRTC` framework.
    ///
    /// > Note: It is recommended to use `RTCAudioSessionConfiguration.webRTC()` to obtain an instance of `RTCAudioSessionConfiguration` instead of instantiating directly.
    ///
    /// View ``defaultShouldConfigureAudioSessionFunc(newState:oldState:)`` for usage of this method.
    ///
    /// - Parameters:
    ///   - configuration: A configured RTCAudioSessionConfiguration
    ///   - setActive: passing true/false will call `AVAudioSession.setActive` internally
    public static func configureAudioSession(_ configuration: RTCAudioSessionConfiguration,
                                             setActive: Bool? = nil) {

        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        defer { audioSession.unlockForConfiguration() }

        do {
            logger.debug("configuring audio session with category: \(configuration.category), mode: \(configuration.mode), setActive: \(String(describing: setActive))")

            if let setActive = setActive {
                try audioSession.setConfiguration(configuration, active: setActive)
            } else {
                try audioSession.setConfiguration(configuration)
            }
        } catch let error {
            logger.error("Failed to configure audio session \(error)")
        }
    }

    /// The default implementation when audio session configuration is requested by the SDK.
    public static func defaultShouldConfigureAudioSessionFunc(newState: AudioTrack.TracksState,
                                                              oldState: AudioTrack.TracksState) {

        let config = RTCAudioSessionConfiguration.webRTC()

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

        configureAudioSession(config, setActive: setActive)
    }
    #endif
}
