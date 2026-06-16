/*
 * Copyright 2026 LiveKit
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

import LiveKit
import SwiftUI

// Exercises a representative slice of the public API (connect + publish camera/mic
// + a video view) so the linker keeps the main code paths.
@MainActor
final class CallModel: ObservableObject, RoomDelegate {
    let room = Room()

    init() {
        room.add(delegate: self)
    }

    func connect() async {
        do {
            try await room.connect(url: "wss://example.livekit.cloud", token: "dev-token")
            try await room.localParticipant.setCamera(enabled: true)
            try await room.localParticipant.setMicrophone(enabled: true)
        } catch {
            print("Failed to connect: \(error)")
        }
    }

    nonisolated func room(
        _: Room,
        participant _: LocalParticipant,
        didPublishTrack publication: LocalTrackPublication,
    ) {
        guard publication.track is VideoTrack else { return }
        print("Published a video track")
    }
}

@main
struct LiveKitApp: App {
    @StateObject private var model = CallModel()

    var body: some Scene {
        WindowGroup {
            VStack {
                Text("LiveKit Hello World")
                if let track = model.room.localParticipant.localVideoTracks.first?.track as? VideoTrack {
                    SwiftUIVideoView(track)
                }
            }
            .task { await model.connect() }
        }
    }
}
