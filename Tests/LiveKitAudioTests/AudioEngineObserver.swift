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

@preconcurrency import AVFoundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

final class TestEngineObserver: AudioEngineObserver, @unchecked Sendable {
    enum Hook: Hashable {
        case willEnable
        case willStart
        case didStop
        case didDisable
        case willRelease
    }

    struct Call: Equatable {
        let hook: Hook
        /// `nil` for hooks that do not report the engine state.
        let isPlayoutEnabled: Bool?
        let isRecordingEnabled: Bool?
    }

    private struct State {
        var failingHooks: Set<Hook> = []
        var calls: [Call] = []
    }

    var next: (any LiveKit.AudioEngineObserver)?
    private let _state = StateSync(State())

    /// Hooks that return an error code until changed.
    var failingHooks: Set<Hook> {
        get { _state.failingHooks }
        set { _state.mutate { $0.failingHooks = newValue } }
    }

    /// Calls since the last ``resetCalls()``, in order.
    var calls: [Call] { _state.calls }

    /// The hooks called since the last ``resetCalls()``, in order.
    var hooks: [Hook] { calls.map(\.hook) }

    func resetCalls() {
        _state.mutate { $0.calls = [] }
    }

    func calls(to hook: Hook) -> [Call] {
        calls.filter { $0.hook == hook }
    }

    private func record(_ hook: Hook, _ isPlayoutEnabled: Bool? = nil, _ isRecordingEnabled: Bool? = nil) -> Int {
        _state.mutate {
            $0.calls.append(Call(hook: hook, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled))
            return $0.failingHooks.contains(hook) ? -1 : 0
        }
    }

    func engineWillEnable(_: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        record(.willEnable, isPlayoutEnabled, isRecordingEnabled)
    }

    func engineWillStart(_: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        record(.willStart, isPlayoutEnabled, isRecordingEnabled)
    }

    func engineDidStop(_: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        record(.didStop, isPlayoutEnabled, isRecordingEnabled)
    }

    func engineDidDisable(_: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        record(.didDisable, isPlayoutEnabled, isRecordingEnabled)
    }

    func engineWillRelease(_: AVAudioEngine) -> Int {
        record(.willRelease)
    }
}

@Suite(.serialized, .tags(.audio)) struct AudioEngineObserverTests {
    // The AudioDeviceModule's observer contract (webrtc-sdk/webrtc#312):
    // - A setup hook (will-enable, will-start) that returns an error fails the operation and rolls it back,
    //   and the SDK throws, in both device and manual rendering modes. A did-disable compensates a successful
    //   will-enable, and a will-release compensates the engine created for the operation.
    // - A teardown hook (did-stop, did-disable, will-release) that returns an error is only logged.
    //   The engine has already stopped, so the operation completes and the SDK does not throw.
    @Test func observerFail() throws {
        let audioManager = AudioManager.shared
        let testObserver = TestEngineObserver()

        // The expected hook states below assume nothing else holds the engine enabled.
        try #require(!audioManager.isEngineRunning)
        try #require(!audioManager.isManualRenderingMode)
        try #require(!audioManager.isRecordingAlwaysPreparedMode)
        try #require(!audioManager.isPlayoutInitialized)
        try #require(!audioManager.isRecordingInitialized)

        // AudioManager is shared by every test in the process, so restore what this test changes
        // even when an expectation fails midway.
        let previousObservers = audioManager._state.engineObservers
        let wasPlatformVoiceProcessingAllowed = audioManager.isPlatformVoiceProcessingAllowed
        #if os(iOS) || os(visionOS) || os(tvOS)
        let previousCategory = AVAudioSession.sharedInstance().category
        #endif
        defer {
            testObserver.failingHooks = []
            try? audioManager.stopLocalRecording()
            try? audioManager.setManualRenderingMode(false)
            audioManager.set(engineObservers: previousObservers)
            try? audioManager.setPlatformVoiceProcessingAllowed(wasPlatformVoiceProcessingAllowed)
            #if os(iOS) || os(visionOS) || os(tvOS)
            try? AVAudioSession.sharedInstance().setCategory(previousCategory)
            #endif
        }

        audioManager.set(engineObservers: [testObserver])

        // Test without enabling VP
        try audioManager.setPlatformVoiceProcessingAllowed(false)

        #if os(iOS) || os(visionOS) || os(tvOS)
        try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playAndRecord)
        #endif

        try deviceRenderingMode(audioManager, testObserver)
        try manualRenderingMode(audioManager, testObserver)
    }

    private var disabled: TestEngineObserver.Call {
        .init(hook: .didDisable, isPlayoutEnabled: false, isRecordingEnabled: false)
    }

    private func deviceRenderingMode(_ audioManager: AudioManager, _ testObserver: TestEngineObserver) throws {
        try audioManager.startLocalRecording()
        #expect(audioManager.isEngineRunning)
        #expect(audioManager.isRecording)

        // Teardown hooks fail: logged only, the stop still succeeds.
        testObserver.failingHooks = [.didStop, .didDisable, .willRelease]
        testObserver.resetCalls()

        #expect(throws: Never.self) { try audioManager.stopLocalRecording() }
        #expect(!audioManager.isEngineRunning)
        #expect(!audioManager.isRecording)
        // Every failing hook was reached, so the stop did not succeed by skipping them.
        #expect(testObserver.hooks == [.didStop, .didDisable, .willRelease])
        #expect(testObserver.calls(to: .didDisable) == [disabled])

        // Stopping again is a no-op and calls no hook.
        testObserver.failingHooks = []
        testObserver.resetCalls()
        try audioManager.stopLocalRecording()
        #expect(!audioManager.isEngineRunning)
        #expect(testObserver.calls.isEmpty)

        // Setup hook fails at will-enable: the start fails and is rolled back. No did-disable follows
        // a will-enable that failed, only the will-release for the engine created by the start.
        testObserver.failingHooks = [.willEnable]
        testObserver.resetCalls()

        #expect(throws: (any Error).self) { try audioManager.startLocalRecording() }
        #expect(!audioManager.isEngineRunning)
        #expect(!audioManager.isRecording)
        #expect(testObserver.hooks == [.willEnable, .willRelease])

        // Setup hook fails at will-start, after a successful will-enable: the start fails and is rolled back.
        // The observer gets a did-disable with the state from before the start, then the will-release.
        testObserver.failingHooks = [.willStart]
        testObserver.resetCalls()

        #expect(throws: (any Error).self) { try audioManager.startLocalRecording() }
        #expect(!audioManager.isEngineRunning)
        #expect(!audioManager.isRecording)
        #expect(testObserver.hooks == [.willEnable, .willStart, .didDisable, .willRelease])
        #expect(testObserver.calls(to: .didDisable) == [disabled])

        // The rollbacks left a clean state: the next start and stop succeed.
        testObserver.failingHooks = []
        try audioManager.startLocalRecording()
        #expect(audioManager.isEngineRunning)
        #expect(audioManager.isRecording)
        try audioManager.stopLocalRecording()
        #expect(!audioManager.isEngineRunning)
        #expect(!audioManager.isRecording)
    }

    private func manualRenderingMode(_ audioManager: AudioManager, _ testObserver: TestEngineObserver) throws {
        // isEngineRunning only reports the device engine, so the manual engine is checked with isRecording.
        try audioManager.setManualRenderingMode(true)

        // Setup hook fails at will-enable: the start fails and is rolled back.
        testObserver.failingHooks = [.willEnable]
        testObserver.resetCalls()

        #expect(throws: (any Error).self) { try audioManager.startLocalRecording() }
        #expect(!audioManager.isRecording)
        #expect(testObserver.calls(to: .willEnable).count == 1)
        #expect(testObserver.calls(to: .didDisable).isEmpty)

        testObserver.failingHooks = []

        try audioManager.startLocalRecording()
        #expect(!audioManager.isEngineRunning)
        #expect(audioManager.isRecording)

        // Teardown hooks fail: logged only, the stop still succeeds.
        testObserver.failingHooks = [.didStop, .didDisable]
        testObserver.resetCalls()

        #expect(throws: Never.self) { try audioManager.stopLocalRecording() }
        #expect(!audioManager.isRecording)
        #expect(testObserver.calls(to: .didStop).count == 1)
        #expect(testObserver.calls(to: .didDisable) == [disabled])
    }
}
