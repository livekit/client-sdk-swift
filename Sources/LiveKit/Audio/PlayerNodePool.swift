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

@preconcurrency import AVFAudio

extension AVAudioEngine {
    func attach(_ playerNodePool: AVAudioPlayerNodePool) {
        // Attach playerNodes
        for playerNode in playerNodePool.playerNodes {
            attach(playerNode)
        }
        // Attach mixerNode
        attach(playerNodePool.mixerNode)
    }

    func detach(_ playerNodePool: AVAudioPlayerNodePool) {
        // Detach playerNodes
        for playerNode in playerNodePool.playerNodes {
            playerNode.stop()
            detach(playerNode)
        }
        // Detach mixerNode
        detach(playerNodePool.mixerNode)
    }

    func connect(_ playerNodePool: AVAudioPlayerNodePool, to node2: AVAudioNode, format: AVAudioFormat?) {
        // Connect playerNodes
        for playerNode in playerNodePool.playerNodes {
            connect(playerNode, to: playerNodePool.mixerNode, format: format)
        }
        // Connect mixerNode
        connect(playerNodePool.mixerNode, to: node2, format: format)
    }
}

// Support scheduling buffer to play concurrently
class AVAudioPlayerNodePool: @unchecked Sendable, Loggable {
    let poolSize: Int
    let mixerNode = AVAudioMixerNode()

    var playerNodes: [AVAudioPlayerNode] {
        _state.read(\.playerNodes)
    }

    var engine: AVAudioEngine? {
        mixerNode.engine
    }

    private struct State {
        var playerNodes: [AVAudioPlayerNode]
    }

    private let audioCallbackQueue = DispatchQueue(label: "audio.playerNodePool.queue")

    private let _state: StateSync<State>

    init(poolSize: Int = 10) {
        self.poolSize = poolSize
        let playerNodes = (0 ..< poolSize).map { _ in AVAudioPlayerNode() }
        _state = StateSync(State(playerNodes: playerNodes))
    }

    func scheduleBuffer(_ buffer: AVAudioPCMBuffer) throws {
        guard let node = nextAvailablePlayerNode() else {
            throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "No available player nodes"])
        }
        log("Next node: \(node)")

        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self, weak node] _ in
            guard let self else { return }
            audioCallbackQueue.async { [weak node] in
                guard let node else { return }
                node.stop() // Stop the node
            }
        }
        node.play()
    }

    // Stops all player nodes
    func stop() {
        for node in _state.read(\.playerNodes) {
            node.stop()
        }
    }

    private func nextAvailablePlayerNode() -> AVAudioPlayerNode? {
        // Find first available node
        guard let node = _state.read({ $0.playerNodes.first(where: { !$0.isPlaying }) }) else {
            return nil
        }

        // Ensure node settings
        node.volume = 1.0
        node.pan = 0.0

        return node
    }
}
