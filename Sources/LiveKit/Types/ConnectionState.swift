/*
 * Copyright 2022 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

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
        lhs.isEqual(to: rhs)
    }

    public func isEqual(to rhs: ConnectMode, includingAssociatedValues: Bool = true) -> Bool {
        switch (self, rhs) {
        case (.reconnect(let mode1), .reconnect(let mode2)): return includingAssociatedValues ? mode1 == mode2 : true
        case (.normal, .normal): return true
        default: return false
        }
    }
}

public enum ConnectionState {
    case disconnected(reason: DisconnectReason? = nil)
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
        lhs.isEqual(to: rhs)
    }

    public func isEqual(to rhs: ConnectionState, includingAssociatedValues: Bool = true) -> Bool {
        switch (self, rhs) {
        case (.disconnected(let reason1), .disconnected(let reason2)):
            if includingAssociatedValues {
                if let reason1 = reason1, let reason2 = reason2 {
                    // both non-nil, compare using isEqual
                    return reason1.isEqual(to: reason2)
                } else if reason1 == nil, reason2 == nil {
                    // both nil, is equal
                    return true
                }
                // one of them are nil, not equal
                return false
            }
            return true
        case (.connecting(let mode1), .connecting(let mode2)):
            return includingAssociatedValues ? mode1.isEqual(to: mode2) : true
        case (.connected(let mode1), .connected(let mode2)):
            return includingAssociatedValues ? mode1.isEqual(to: mode2) : true
        default: return false
        }
    }

    public var isConnected: Bool {
        guard case .connected = self else { return false }
        return true
    }

    public var isDisconnected: Bool {
        guard case .disconnected = self else { return false }
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
        guard case .disconnected(let reason) = self,
              case .networkError(let error) = reason else { return nil }
        return error
    }
}

public enum DisconnectReason {
    case user // User initiated
    case networkError(_ error: Error? = nil)
}

extension DisconnectReason: Equatable {

    public static func == (lhs: DisconnectReason, rhs: DisconnectReason) -> Bool {
        lhs.isEqual(to: rhs)
    }

    public func isEqual(to rhs: DisconnectReason, includingAssociatedValues: Bool = true) -> Bool {
        switch (self, rhs) {
        case (.user, .user): return true
        case (.networkError, .networkError): return true
        default: return false
        }
    }

    var error: Error? {
        if case .networkError(let error) = self {
            return error
        }

        return nil
    }
}
