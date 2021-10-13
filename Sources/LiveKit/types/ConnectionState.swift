import Foundation

public enum ConnectionState {
    case disconnected(Error? = nil)
    case connecting(isReconnecting: Bool)
    case connected
}

extension ConnectionState: Equatable {

    public static func ==(lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (let .connecting(r1), let .connecting(r2)): return r1 == r2
        case (.disconnected, .disconnected): return true
        case (.connected, .connected): return true
        default: return false
        }
    }

    public var isReconnecting: Bool {
        if case .connecting(isReconnecting: true) = self { return true }
        return false
    }
}
