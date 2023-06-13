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

/// Loops through `Participant`'s in the current `Room`.
///
/// > Note: References `Room` environment object.
public struct ForEachParticipant<Content: View>: View {

    @EnvironmentObject var room: Room

    let content: ParticipantComponentBuilder<Content>

    public init(@ViewBuilder content: @escaping ParticipantComponentBuilder<Content>) {
        self.content = content
    }

    private func sortedParticipants() -> [Participant] {
        room.allParticipants.values.sorted { p1, p2 in
            if p1 is LocalParticipant { return true }
            if p2 is LocalParticipant { return false }
            return (p1.joinedAt ?? Date()) < (p2.joinedAt ?? Date())
        }
    }

    public var body: some View {
        ForEach(sortedParticipants()) { participant in
            content(participant)
                .environmentObject(participant)
        }
    }
}
