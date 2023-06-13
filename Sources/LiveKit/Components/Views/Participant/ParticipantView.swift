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

public struct ParticipantView: View {

    @EnvironmentObject var participant: Participant
    @EnvironmentObject var ui: UIPreference

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let trackPublication = participant.firstCameraPublication {
                    VideoTrackPublicationView()
                        .environmentObject(trackPublication)
                } else {
                    ui.videoDisabledView(geometry: geometry)
                }
                ParticipantInformationView()
                    .padding(5)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(7)
                    .padding()
            }
        }
    }
}
