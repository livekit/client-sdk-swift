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

public struct ConnectView: View {

    @EnvironmentObject var room: Room
    @EnvironmentObject var ui: UIPreference

    @AppStorage("url") var url: String = ""
    @AppStorage("token") var token: String = ""

    public var body: some View {

        VStack(spacing: 15) {

            ui.textFieldContainer {
                ui.textField(for: $url, type: .url)
            } label: {
                Text("URL")
            }

            ui.textFieldContainer {
                ui.textField(for: $token, type: .token)
            } label: {
                Text("Token")
            }

            if case .connecting = room.connectionState {
                ProgressView()
            } else {
                ui.button {
                    Task {
                        room.connect(url: url, token: token)
                    }
                } label: {
                    Text("Connect")
                }
                .disabled(!room.connectionState.isDisconnected)
            }
        }
    }
}
