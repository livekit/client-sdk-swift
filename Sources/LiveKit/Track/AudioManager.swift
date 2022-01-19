import Foundation
import WebRTC

// Audio Session Configuration related
public class AudioManager: Loggable {

    public enum State {
        case none
        case localOnly
        case remoteOnly
        case localAndRemote
    }

    internal enum `Type` {
        case local
        case remote
    }

    public static let shared = AudioManager()

    public private(set) var state: State = .none {
        didSet {
            guard oldValue != state else { return }
            log("AudioManager.state didUpdate \(oldValue) -> \(state)")
            #if os(iOS)
            LiveKit.onShouldConfigureAudioSession(state, oldValue)
            #endif
        }
    }

    public private(set) var localTracksCount = 0 {
        didSet { recomputeState() }
    }

    public private(set) var remoteTracksCount = 0 {
        didSet { recomputeState() }
    }

    // Singleton
    private init() {}

    internal func trackDidStart(_ type: Type) {
        if type == .local { localTracksCount += 1 }
        if type == .remote { remoteTracksCount += 1 }
    }

    internal func trackDidStop(_ type: Type) {
        if type == .local { localTracksCount -= 1 }
        if type == .remote { remoteTracksCount -= 1 }

    }

    private func recomputeState() {
        if localTracksCount > 0 && remoteTracksCount == 0 {
            state = .localOnly
        } else if localTracksCount == 0 && remoteTracksCount > 0 {
            state = .remoteOnly
        } else if localTracksCount > 0 && remoteTracksCount > 0 {
            state = .localAndRemote
        } else {
            state = .none
        }
    }
}
