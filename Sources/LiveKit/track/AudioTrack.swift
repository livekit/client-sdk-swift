import Foundation
import WebRTC

public class AudioTrack: Track {

    public enum TracksState {
        case none
        case localOnly
        case remoteOnly
        case localAndRemote
    }

    public private(set) var sinks: [AudioSink]?
    public var audioTrack: RTCAudioTrack {
        get { return mediaTrack as! RTCAudioTrack }
    }

    private static var localTracksCount = 0
    private static var remoteTracksCount = 0

    internal static var tracksState: TracksState = .none {
        didSet {
            guard oldValue != tracksState else { return }
            AudioTrack.shouldConfigureAudioSession()
        }
    }

    init(rtcTrack: RTCAudioTrack, name: String) {
        super.init(name: name, kind: .audio, track: rtcTrack)
    }

    // MARK: - Public Methods

    public func addSink(_ sink: AudioSink) {
        sinks?.append(sink)
    }

    public func removeSink(_ sink: AudioSink) {
        sinks?.removeAll(where: { s -> Bool in
            (sink as AnyObject) === (s as AnyObject)
        })
    }

    // MARK: - Internal Methods

    internal override func stateUpdated() {
        super.stateUpdated()
        let delta = state == .started ? 1 : -1
        if self is LocalAudioTrack {
            AudioTrack.localTracksCount += delta
        } else {
            AudioTrack.remoteTracksCount += delta
        }
        AudioTrack.computeTracksState()
    }
}

// MARK: - Audio Session Configuration related

extension AudioTrack {

    internal static func computeTracksState() {
        if localTracksCount > 0 && remoteTracksCount == 0 {
            tracksState = .localOnly
        } else if localTracksCount == 0 && remoteTracksCount > 0 {
            tracksState = .remoteOnly
        } else if localTracksCount > 0 && remoteTracksCount > 0 {
            tracksState = .localAndRemote
        } else {
            tracksState = .none
        }
    }

    internal static func shouldConfigureAudioSession() {
        let config = RTCAudioSessionConfiguration.webRTC()
        guard LiveKit.onConfigureAudioSession(tracksState, config) else {
            return
        }
        logger.debug("configuring audio session category \(config.category), mode \(config.mode)")
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        defer { audioSession.unlockForConfiguration() }
        do {
            try audioSession.setConfiguration(config, active: true)
        } catch let error {
            logger.error("Failed to configure audio session \(error)")
        }
    }
}
