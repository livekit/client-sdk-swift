/*
 * Copyright 2023 LiveKit
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

import SwiftUI
import LiveKit

/// Switch the view to build depending on the `Room`'s `ConnectionState`.
///
/// > Note: References `Room` environment object.
public struct ConnectionStateBuilder<DisconnectedView: View,
                                     ConnectingView: View,
                                     ReconnectingView: View,
                                     ConnectedView: View>: View {

    public typealias DisconnectedComponentBuilder<Content: View> = (_ reason: DisconnectReason?) -> Content

    @EnvironmentObject var room: Room

    var disconnected: DisconnectedComponentBuilder<DisconnectedView>
    var connecting: ComponentBuilder<ConnectingView>
    var reconnecting: ComponentBuilder<ReconnectingView>
    var connected: ComponentBuilder<ConnectedView>

    public init(@ViewBuilder disconnected: @escaping DisconnectedComponentBuilder<DisconnectedView>,
                             @ViewBuilder connecting: @escaping ComponentBuilder<ConnectingView>,
                             @ViewBuilder reconnecting: @escaping ComponentBuilder<ReconnectingView>,
                             @ViewBuilder connected: @escaping ComponentBuilder<ConnectedView>) {

        self.disconnected = disconnected
        self.connecting = connecting
        self.reconnecting = reconnecting
        self.connected = connected
    }

    public var body: some View {
        switch room.connectionState {
        case .disconnected(let reason): return AnyView(disconnected(reason))
        case .connecting: return AnyView(connecting())
        case .reconnecting: return AnyView(reconnecting())
        case .connected: return AnyView(connected())
        }
    }
}
