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

import Foundation
@testable import LiveKit
import Testing

struct SoundPlayerObserverTests {
    @Test
    func unregistersObserverWhenReleasedOutsideActor() async {
        let center = TrackingNotificationCenter()
        var player: SoundPlayer? = await SoundPlayer(notificationCenter: center)
        weak var weakPlayer = player
        #expect(weakPlayer != nil)
        #expect(center.removalCount.copy() == 0)

        player = nil

        #expect(weakPlayer == nil)
        #expect(center.removalCount.copy() == 1)
    }
}

private final class TrackingNotificationCenter: NotificationCenter, @unchecked Sendable {
    let removalCount = StateSync(0)

    override func removeObserver(_ observer: Any) {
        removalCount.mutate { $0 += 1 }
        super.removeObserver(observer)
    }
}
