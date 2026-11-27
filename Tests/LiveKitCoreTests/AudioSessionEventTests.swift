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

#if os(iOS) || os(visionOS) || os(tvOS)

import AVFoundation
import Foundation
@testable import LiveKit
import Testing

/// Audio session events (interruptions and media services resets) through the engine observer chain.
/// `AVAudioSession` is never touched.
struct AudioSessionEventTests {
    /// Implements none of the audio session hooks, so the protocol's default implementations apply.
    private final class PassThroughObserver: AudioEngineObserver, @unchecked Sendable {
        var next: (any AudioEngineObserver)?
    }

    /// Collects the events forwarded down the chain.
    private final class EventCollector: AudioEngineObserver, @unchecked Sendable {
        var next: (any AudioEngineObserver)?
        let events = StateSync<[AudioSessionEvent]>([])

        func audioSessionDidBeginInterruption(reason: AVAudioSession.InterruptionReason) {
            events.mutate { $0.append(.interruptionBegan(reason: reason)) }
        }

        func audioSessionDidEndInterruption(shouldResume: Bool) {
            events.mutate { $0.append(.interruptionEnded(shouldResume: shouldResume)) }
        }

        func audioSessionMediaServicesWereReset() {
            events.mutate { $0.append(.mediaServicesWereReset) }
        }
    }

    // MARK: - Forwarding

    /// An observer that does not implement the hooks still passes the events to the next observer.
    @Test func defaultImplementationsForwardToTheNextObserver() {
        let observer = PassThroughObserver()
        let collector = EventCollector()
        observer.next = collector

        observer.audioSessionDidBeginInterruption(reason: .builtInMicMuted)
        observer.audioSessionDidEndInterruption(shouldResume: false)
        observer.audioSessionMediaServicesWereReset()

        #expect(collector.events.copy() == [
            .interruptionBegan(reason: .builtInMicMuted),
            .interruptionEnded(shouldResume: false),
            .mediaServicesWereReset,
        ])
    }

    /// The SDK's session observer forwards interruption events to the observers after it.
    @Test func sessionObserverForwardsInterruptionEvents() {
        let observer = AudioSessionEngineObserver()
        let collector = EventCollector()
        observer.next = collector

        observer.audioSessionDidBeginInterruption(reason: .default)
        observer.audioSessionDidEndInterruption(shouldResume: true)

        #expect(collector.events.copy() == [.interruptionBegan(reason: .default), .interruptionEnded(shouldResume: true)])
    }
}

#endif
