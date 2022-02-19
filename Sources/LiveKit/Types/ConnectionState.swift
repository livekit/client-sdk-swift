import Foundation

public enum ReconnectMode {
    case quick
    case full
}

public enum ConnectMode {
    case normal
    case reconnect(_ mode: ReconnectMode)
}

extension ConnectMode: Equatable {

    public static func == (lhs: ConnectMode, rhs: ConnectMode) -> Bool {
        switch (lhs, rhs) {
        case (let .reconnect(type1), let .reconnect(type2)): return type1 == type2
        case (.normal, .normal): return true
        default: return false
        }
    }
}

public enum ConnectionState {
    case disconnected(reason: DisconnectReason)
    case connecting(_ mode: ConnectMode)
    case connected(_ mode: ConnectMode)
}

extension ConnectionState: Identifiable {
    public var id: String {
        String(describing: self)
    }
}

extension ConnectionState: Equatable {

    public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected(let m1), .disconnected(let m2)): return m1 == m2
        case (.connecting(let r1), .connecting(let r2)): return r1 == r2
        case (.connected(let m1), .connected(let m2)): return m1 == m2
        default: return false
        }
    }

    public var isConnected: Bool {
        guard case .connected = self else { return false }
        return true
    }

    public var isReconnecting: Bool {
        return reconnectingWithMode != nil
    }

    public var didReconnect: Bool {
        return reconnectedWithMode != nil
    }

    public var reconnectingWithMode: ReconnectMode? {
        guard case .connecting(let c) = self,
              case .reconnect(let r) = c else { return nil }
        return r
    }

    public var reconnectedWithMode: ReconnectMode? {
        guard case .connected(let c) = self,
              case .reconnect(let r) = c else { return nil }
        return r
    }

    public var disconnectedWithError: Error? {
        guard case .disconnected(let r) = self else { return nil }
        return r.error
    }
}

public enum DisconnectReason {
    case user // User initiated
    case network(error: Error? = nil)
    case sdk //
}

extension DisconnectReason: Equatable {

    public static func == (lhs: DisconnectReason, rhs: DisconnectReason) -> Bool {
        switch (lhs, rhs) {
        case (.user, .user): return true
        case (.network, .network): return true
        case (.sdk, .sdk): return true
        default: return false
        }
    }

    var error: Error? {
        if case .network(let error) = self {
            return error
        }

        return nil
    }
}
