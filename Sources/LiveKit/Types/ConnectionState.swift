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

@objc
public enum ReconnectMode: Int {
    case quick
    case full
}

public enum ConnectionState {
    case disconnected(reason: DisconnectReason? = nil)
    case connecting
    case reconnecting
    case connected

    internal func toObjCType() -> ConnectionStateObjC {
        switch self {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .reconnecting: return .reconnecting
        case .connected: return .connected
        }
    }
}

extension ConnectionState: Identifiable {
    public var id: String {
        String(describing: self)
    }
}

extension ConnectionState: Equatable {

    public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.reconnecting, .reconnecting),
             (.connected, .connected):
            return true
        default: return false
        }
    }

    public var isConnected: Bool {
        guard case .connected = self else { return false }
        return true
    }

    public var isReconnecting: Bool {
        guard case .reconnecting = self else { return false }
        return true
    }

    public var isDisconnected: Bool {
        guard case .disconnected = self else { return false }
        return true
    }

    public var disconnectedWithNetworkError: Error? {
        guard case .disconnected(let reason) = self,
              case .networkError(let error) = reason else { return nil }
        return error
    }

    @available(*, deprecated, renamed: "disconnectedWithNetworkError")
    public var disconnectedWithError: Error? { disconnectedWithNetworkError }
}

protocol ReconnectableState {
    var reconnectMode: ReconnectMode? { get }
    var connectionState: ConnectionState { get }
}
