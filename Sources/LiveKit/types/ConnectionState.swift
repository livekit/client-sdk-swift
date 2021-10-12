import Foundation

public enum ConnectionState {
    case disconnected(Error? = nil)
    case connecting(isReconnecting: Bool)
    case connected
}

extension ConnectionState: Equatable {

    public static func ==(lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (let .connecting(a1), let .connecting(a2)): return a1 == a2
        case (.disconnected, .disconnected): return true
        case (.connected, .connected): return true
        default: return false
        }
    }
}
