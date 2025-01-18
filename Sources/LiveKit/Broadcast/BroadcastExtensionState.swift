/*
 * Copyright 2025 LiveKit
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

#if os(iOS)

import AsyncAlgorithms
import Foundation

#if canImport(ReplayKit)
import ReplayKit
#endif

actor BroadcastExtensionState {
    /// Whether or not the broadcast extension is currently broadcasting.
    private(set) var isBroadcasting = false

    /// Displays the system broadcast picker, allowing the user to start the broadcast.
    /// - Note: This is merely a request and does not guarantee the user will choose to start the broadcast.
    nonisolated func requestActivation() async {
        await RPSystemBroadcastPickerView.show(
            for: BroadcastScreenCapturer.screenSharingExtension,
            showsMicrophoneButton: false
        )
    }

    private var listenTask: Task<Void, Never>?

    /// Creates a new instance and begins listening.
    init(_ changeHandler: ((Bool) async -> Void)? = nil) async {
        listenTask = Task {
            let stateStream = merge(
                DarwinNotificationCenter.shared.notifications(named: .broadcastStarted).map { true },
                DarwinNotificationCenter.shared.notifications(named: .broadcastStopped).map { false }
            )
            for await isBroadcasting in stateStream {
                self.isBroadcasting = isBroadcasting
                await changeHandler?(isBroadcasting)
            }
        }
    }

    deinit {
        listenTask?.cancel()
    }
}

#endif
