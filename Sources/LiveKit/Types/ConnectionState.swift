import Foundation

public enum ConnectionState {
    case disconnected(reason: DisconnectReason? = nil)
    case connecting(isReconnecting: Bool)
    case connected(didReconnect: Bool = false)
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

    //    /// true when connecting or re-connecting
    //    public var isConnecting: Bool {
    //        if case .connecting = self { return true }
    //        return false
    //    }

    /// true only when is re-connecting
    public var isReconnecting: Bool {
        if case .connecting(isReconnecting: true) = self { return true }
        return false
    }
}

public enum DisconnectReason {
    case user // User initiated
    case network(error: Error? = nil)
    case sdk //
}

extension DisconnectReason {

    var error: Error? {
        if case .network(let error) = self {
            return error
        }

        return nil
    }
}
