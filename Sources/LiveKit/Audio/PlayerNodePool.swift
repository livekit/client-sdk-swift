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

/// Represents an active sound playback that can be stopped.
protocol SoundPlayback: AnyObject, Sendable {
    var isPlaying: Bool { get }
    func stop()
}

/// Manages a pool of AVAudioPlayerNodes for concurrent audio playback.
class AVAudioPlayerNodePool: @unchecked Sendable, Loggable {
    let poolSize: Int
    let mixerNode = AVAudioMixerNode()

    var playerNodes: [AVAudioPlayerNode] {
        _state.read { $0.map(\.node) }
    }

    var engine: AVAudioEngine? {
        mixerNode.engine
    }

    private struct NodeItem {
        let node: AVAudioPlayerNode
        var isInUse: Bool = false
        var generation: UInt64 = 0
    }

    private let audioCallbackQueue = DispatchQueue(label: "audio.playerNodePool.queue")
    private let _state: StateSync<[NodeItem]>

    init(poolSize: Int = 10) {
        self.poolSize = poolSize
        let items = (0 ..< poolSize).map { _ in NodeItem(node: AVAudioPlayerNode()) }
        _state = StateSync(items)
    }

    private struct AcquiredNode {
        let index: Int
        let node: AVAudioPlayerNode
        let generation: UInt64
    }

    @discardableResult
    func play(_ buffer: AVAudioPCMBuffer, loop: Bool = false) throws -> SoundPlayback {
        guard let acquired = _state.mutate({ items -> AcquiredNode? in
            guard let index = items.firstIndex(where: { !$0.isInUse }) else {
                return nil
            }
            items[index].isInUse = true
            items[index].generation &+= 1
            let node = items[index].node
            node.volume = 1.0
            node.pan = 0.0
            return AcquiredNode(index: index, node: node, generation: items[index].generation)
        }) else {
            throw LiveKitError(.audioEngine, message: "No available player nodes")
        }

        if loop {
            acquired.node.scheduleBuffer(buffer, at: nil, options: .loops)
        } else {
            acquired.node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.audioCallbackQueue.async { [weak self] in
                    self?.freeSlot(index: acquired.index, generation: acquired.generation)
                }
            }
        }
        acquired.node.play()

        return NodePlayback(node: acquired.node) { [weak self] in
            self?.freeSlot(index: acquired.index, generation: acquired.generation)
        }
    }

    func stop() {
        let nodes = _state.mutate { items in
            for index in items.indices {
                items[index].isInUse = false
                items[index].generation &+= 1
            }
            return items.map(\.node)
        }
        for node in nodes {
            node.stop()
        }
    }

    func reset() {
        let nodes = _state.mutate { items in
            for index in items.indices {
                items[index].isInUse = false
                items[index].generation &+= 1
            }
            return items.map(\.node)
        }
        for node in nodes {
            node.reset()
        }
    }

    private func freeSlot(index: Int, generation: UInt64) {
        _state.mutate { items in
            guard items[index].generation == generation else { return }
            items[index].isInUse = false
            items[index].node.stop()
        }
    }
}

// MARK: - NodePlayback

class NodePlayback: SoundPlayback, @unchecked Sendable {
    private weak var node: AVAudioPlayerNode?
    private let onStop: @Sendable () -> Void

    var isPlaying: Bool { node?.isPlaying ?? false }

    init(node: AVAudioPlayerNode, onStop: @escaping @Sendable () -> Void) {
        self.node = node
        self.onStop = onStop
    }

    func stop() {
        node?.stop()
        onStop()
    }
}

// MARK: - AVAudioEngine extensions

extension AVAudioEngine {
    func attach(_ playerNodePool: AVAudioPlayerNodePool) {
        for playerNode in playerNodePool.playerNodes {
            attach(playerNode)
        }
        attach(playerNodePool.mixerNode)
    }

    func detach(_ playerNodePool: AVAudioPlayerNodePool) {
        for playerNode in playerNodePool.playerNodes {
            playerNode.stop()
            detach(playerNode)
        }
        detach(playerNodePool.mixerNode)
    }

    func connect(_ playerNodePool: AVAudioPlayerNodePool, to node2: AVAudioNode, format: AVAudioFormat?, playerNodeFormat: AVAudioFormat?) {
        for playerNode in playerNodePool.playerNodes {
            connect(playerNode, to: playerNodePool.mixerNode, format: playerNodeFormat ?? format)
        }
        connect(playerNodePool.mixerNode, to: node2, format: format)
    }
}
