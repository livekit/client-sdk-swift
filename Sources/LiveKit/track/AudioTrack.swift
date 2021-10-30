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

    private static var localTracksCount = 0 {
        didSet { recomputeTracksState() }
    }

    private static var remoteTracksCount = 0 {
        didSet { recomputeTracksState() }
    }

    internal static var tracksState: TracksState = .none {
        didSet {
            guard oldValue != tracksState else { return }
            #if !os(macOS)
            LiveKit.onShouldConfigureAudioSession(tracksState, oldValue)
            #endif
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
    }
}

// MARK: - Audio Session Configuration related

extension AudioTrack {

    internal static func recomputeTracksState() {
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
}
