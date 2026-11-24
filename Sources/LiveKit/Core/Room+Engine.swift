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

public enum StartReconnectReason: Sendable {
    case websocket
    case transport
    case networkSwitch
    case debug
}

extension Room {
    typealias ConditionEvalFunc = @Sendable (_ newState: State, _ oldState: State?) -> Bool
    struct ConditionalExecutionEntry {
        let executeCondition: ConditionEvalFunc
        let removeCondition: ConditionEvalFunc
        let block: @Sendable () -> Void
    }

    func requirePublisher() throws -> Transport {
        throw LiveKitError(.invalidState, message: "Media publication is not available in this native artifact")
    }

    func publisherShouldNegotiate(force _: Bool = false) async throws {
        throw LiveKitError(.invalidState, message: "Swift peer negotiation is unavailable on the native backend")
    }

    func send(userPacket: Livekit_UserPacket, kind: Livekit_DataPacket_Kind) async throws {
        let session = try requireNativeSession(forEncryptedPayload: true)
        do {
            try await session.publishData(payload: userPacket.payload,
                                          options: .init(reliable: kind == .reliable, topic: userPacket.topic,
                                                         destinationIdentities: userPacket.destinationIdentities))
        } catch { throw LiveKitError.mappingNative(error) }
    }

    func send(dataPacket packet: consuming Livekit_DataPacket) async throws {
        guard case let .user(user) = packet.value else {
            throw LiveKitError(.invalidState, message: "This packet operation is not exported by the native session")
        }
        try await send(userPacket: user, kind: packet.kind)
    }

    func execute(when condition: @escaping ConditionEvalFunc,
                 removeWhen removeCondition: @escaping ConditionEvalFunc,
                 _ block: @Sendable @escaping () -> Void)
    {
        // already matches condition, execute immediately
        if _state.read({ condition($0, nil) }) {
            log("[execution control] executing immediately...")
            block()
        } else {
            _blockProcessQueue.async { [weak self] in
                guard let self else { return }

                // create an entry and enqueue block
                log("[execution control] enqueuing entry...")

                let entry = ConditionalExecutionEntry(executeCondition: condition,
                                                      removeCondition: removeCondition,
                                                      block: block)

                _queuedBlocks.append(entry)
            }
        }
    }
}
