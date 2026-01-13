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

@testable import LiveKit
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
import LiveKitWebRTC

struct TestEngineTransition {
    let outputEnabled: ValueOrAbsent<Bool>
    let outputRunning: ValueOrAbsent<Bool>
    let inputEnabled: ValueOrAbsent<Bool>
    let inputRunning: ValueOrAbsent<Bool>
    let legacyMuteMode: ValueOrAbsent<Bool>
    let inputMuted: ValueOrAbsent<Bool>

    init(outputEnabled: ValueOrAbsent<Bool> = .absent,
         outputRunning: ValueOrAbsent<Bool> = .absent,
         inputEnabled: ValueOrAbsent<Bool> = .absent,
         inputRunning: ValueOrAbsent<Bool> = .absent,
         legacyMuteMode: ValueOrAbsent<Bool> = .absent,
         inputMuted: ValueOrAbsent<Bool> = .absent)
    {
        self.outputEnabled = outputEnabled
        self.outputRunning = outputRunning
        self.inputEnabled = inputEnabled
        self.inputRunning = inputRunning
        self.legacyMuteMode = legacyMuteMode
        self.inputMuted = inputMuted
    }
}

struct TestEngineAssert: Hashable {
    let engineRunning: Bool
}

struct TestEngineStep {
    let transition: TestEngineTransition
    let assert: TestEngineAssert
}

extension LKRTCAudioEngineState: Swift.CustomStringConvertible {
    public var description: String {
        "EngineState(" +
            "outputEnabled: \(outputEnabled), " +
            "outputRunning: \(outputRunning), " +
            "inputEnabled: \(inputEnabled), " +
            "inputRunning: \(inputRunning), " +
            "inputMuted: \(inputMuted), " +
            "muteMode: \(muteMode)" +
            ")"
    }
}

func applyEngineTransition(_ transition: TestEngineTransition) {
    let adm = AudioManager.shared
    var engineState = adm.engineState

    if case let .value(value) = transition.outputEnabled {
        engineState.outputEnabled = ObjCBool(value)
    }

    if case let .value(value) = transition.outputRunning {
        engineState.outputRunning = ObjCBool(value)
    }

    if case let .value(value) = transition.inputEnabled {
        engineState.inputEnabled = ObjCBool(value)
    }

    if case let .value(value) = transition.inputRunning {
        engineState.inputRunning = ObjCBool(value)
    }

    if case let .value(value) = transition.inputMuted {
        engineState.inputMuted = ObjCBool(value)
    }

    if case let .value(value) = transition.legacyMuteMode {
        engineState.muteMode = value ? .restartEngine : .voiceProcessing
    }

    print("Testing engine state: \(engineState)")
    adm.engineState = engineState
}

let standardEngineSteps: [TestEngineStep] = [
    // Enable output
    TestEngineStep(transition: .init(outputEnabled: .value(true)), assert: .init(engineRunning: false)),
    TestEngineStep(transition: .init(outputRunning: .value(true)), assert: .init(engineRunning: true)),
    // Enable input
    TestEngineStep(transition: .init(inputEnabled: .value(true)), assert: .init(engineRunning: true)),
    TestEngineStep(transition: .init(inputRunning: .value(true)), assert: .init(engineRunning: true)),
    // Disable input
    TestEngineStep(transition: .init(inputRunning: .value(false)), assert: .init(engineRunning: true)),
    TestEngineStep(transition: .init(inputEnabled: .value(false)), assert: .init(engineRunning: true)),
    // Disable output
    TestEngineStep(transition: .init(outputRunning: .value(false)), assert: .init(engineRunning: false)),
    TestEngineStep(transition: .init(outputEnabled: .value(false)), assert: .init(engineRunning: false)),
]

let muteEngineSteps: [TestEngineStep] = [
    // Enable output
    TestEngineStep(transition: .init(outputEnabled: .value(true)), assert: .init(engineRunning: false)),
    TestEngineStep(transition: .init(outputRunning: .value(true)), assert: .init(engineRunning: true)),

    // Enable input
    TestEngineStep(transition: .init(inputEnabled: .value(true)), assert: .init(engineRunning: true)),
    TestEngineStep(transition: .init(inputRunning: .value(true)), assert: .init(engineRunning: true)),

    // Toggle mute
    TestEngineStep(transition: .init(inputMuted: .value(true)), assert: .init(engineRunning: true)),
    TestEngineStep(transition: .init(inputMuted: .value(false)), assert: .init(engineRunning: true)),

    // Enable legacy mute mode
    TestEngineStep(transition: .init(legacyMuteMode: .value(true)), assert: .init(engineRunning: true)),

    // Disable output
    TestEngineStep(transition: .init(outputRunning: .value(false)), assert: .init(engineRunning: true)),
    TestEngineStep(transition: .init(outputEnabled: .value(false)), assert: .init(engineRunning: true)),

    // Engine should shut down at this point
    TestEngineStep(transition: .init(inputMuted: .value(true)), assert: .init(engineRunning: false)),

    // Engine starts
    TestEngineStep(transition: .init(inputMuted: .value(false)), assert: .init(engineRunning: true)),

    // Enable output
    TestEngineStep(transition: .init(outputEnabled: .value(true)), assert: .init(engineRunning: true)),
    TestEngineStep(transition: .init(outputRunning: .value(true)), assert: .init(engineRunning: true)),

    // Mute
    TestEngineStep(transition: .init(inputMuted: .value(true)), assert: .init(engineRunning: true)),

    // Disable input
    TestEngineStep(transition: .init(inputRunning: .value(false)), assert: .init(engineRunning: true)),
    TestEngineStep(transition: .init(inputEnabled: .value(false)), assert: .init(engineRunning: true)),

    // Disable output
    TestEngineStep(transition: .init(outputRunning: .value(false)), assert: .init(engineRunning: false)),
    TestEngineStep(transition: .init(outputEnabled: .value(false)), assert: .init(engineRunning: false)),
]

class MuteTests: LKTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTransitions() async throws {
        let adm = AudioManager.shared

        for step in muteEngineSteps {
            applyEngineTransition(step.transition)
            // Check if engine running state is correct.
            XCTAssert(adm.isEngineRunning == step.assert.engineRunning)

            let ns = UInt64(1 * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns)
        }
    }
}
