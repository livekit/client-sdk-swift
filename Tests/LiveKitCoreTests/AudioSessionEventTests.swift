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

/// Audio session events (interruptions and media services resets) through the engine observer chain,
/// and the bookkeeping of ``AudioSessionEngineObserver`` around them. `AVAudioSession` is never
/// touched: configuration is recorded instead of applied.
struct AudioSessionEventTests {
    private typealias Observer = AudioSessionEngineObserver

    private final class RecordingObserver: AudioSessionEngineObserver, @unchecked Sendable {
        struct Configuration {
            let oldState: Observer.State
            let newState: Observer.State
            var activates: Bool { Observer.requiresActivation(oldState: oldState, newState: newState) }
        }

        let configurations = StateSync<[Configuration]>([])

        override func configureAudioSession(oldState: Observer.State, newState: Observer.State) throws {
            configurations.mutate { $0.append(Configuration(oldState: oldState, newState: newState)) }
        }

        func takeConfigurations() -> [Configuration] {
            configurations.mutate {
                let configurations = $0
                $0 = []
                return configurations
            }
        }
    }

    private func startedObserver() -> (RecordingObserver, AVAudioEngine) {
        let observer = RecordingObserver()
        let engine = AVAudioEngine()
        _ = observer.engineWillEnable(engine, isPlayoutEnabled: true, isRecordingEnabled: true)
        _ = observer.takeConfigurations()
        return (observer, engine)
    }

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

    // MARK: - Activation decision

    @Test func activationFollowsRequirementsAndNeedsActivation() {
        var inactive = Observer.State()
        var active = Observer.State()
        active.sessionRequirements = [UUID(): .playbackOnly]

        #expect(Observer.requiresActivation(oldState: inactive, newState: active))
        #expect(!Observer.requiresActivation(oldState: active, newState: active))
        #expect(!Observer.requiresActivation(oldState: active, newState: inactive))

        active.needsActivation = true
        #expect(Observer.requiresActivation(oldState: active, newState: active))
        // Nothing to activate for when no requirement is held.
        inactive.needsActivation = true
        #expect(!Observer.requiresActivation(oldState: active, newState: inactive))
    }

    // MARK: - Media services reset

    /// With automatic configuration disabled the observer only updates its bookkeeping, so this runs
    /// without the engine rebuild that would otherwise be scheduled.
    @Test func mediaServicesResetMarksTheSessionForActivationAndForwards() throws {
        let (observer, engine) = startedObserver()
        let collector = EventCollector()
        observer.next = collector
        observer.isAutomaticConfigurationEnabled = false

        observer.audioSessionMediaServicesWereReset()

        #expect(observer._state.needsActivation)
        #expect(collector.events.copy() == [.mediaServicesWereReset])
        #expect(observer.takeConfigurations().isEmpty)

        // Once the app turns automatic configuration back on, the next change activates.
        observer.isAutomaticConfigurationEnabled = true
        _ = observer.engineDidDisable(engine, isPlayoutEnabled: true, isRecordingEnabled: false)
        let configuration = try #require(observer.takeConfigurations().first)
        #expect(configuration.activates)
        #expect(!observer._state.needsActivation)
    }

    @Test func reactivationAfterResetAppliesTheConfiguration() throws {
        let (observer, _) = startedObserver()
        observer._state.mutate { $0.needsActivation = true }

        try observer.reactivateSessionIfNeeded()

        let configuration = try #require(observer.takeConfigurations().first)
        #expect(configuration.activates)
        #expect(!observer._state.needsActivation)

        // Nothing left to do.
        try observer.reactivateSessionIfNeeded()
        #expect(observer.takeConfigurations().isEmpty)
    }
}

#endif
