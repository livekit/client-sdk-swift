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

import DequeModule
import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

// MARK: - Internal delegate

protocol DataChannelDelegate {
    func dataChannel(_ dataChannelPair: DataChannelPair, didReceiveDataPacket dataPacket: Livekit_DataPacket)
}

class DataChannelPair: NSObject, Loggable {
    // MARK: - Public

    public let delegates = MulticastDelegate<DataChannelDelegate>(label: "DataChannelDelegate")

    public let openCompleter = AsyncCompleter<Void>(label: "Data channel open", defaultTimeout: .defaultPublisherDataChannelOpen)

    public var isOpen: Bool { _state.isOpen }

    // MARK: - Private

    private struct State {
        var lossy: LKRTCDataChannel?
        var reliable: LKRTCDataChannel?

        var isOpen: Bool {
            guard let lossy, let reliable else { return false }
            return reliable.readyState == .open && lossy.readyState == .open
        }
    }

    private let _state: StateSync<State>

    fileprivate enum ChannelKind {
        case lossy, reliable
    }

    private struct BufferingState {
        var queue: Deque<PublishDataRequest> = []
        var amount: UInt64 = 0
    }

    private struct PublishDataRequest {
        let data: LKRTCDataBuffer
        let continuation: CheckedContinuation<Void, any Error>?
    }

    private struct ChannelEvent {
        let channelKind: ChannelKind
        let detail: Detail

        enum Detail {
            case publishData(PublishDataRequest)
            case bufferedAmountChanged(UInt64)
        }
    }

    private var eventContinuation: AsyncStream<ChannelEvent>.Continuation?

    @Sendable private func handleEvents(
        events: AsyncStream<ChannelEvent>
    ) async {
        var lossyBuffering = BufferingState()
        var reliableBuffering = BufferingState()

        for await event in events {
            switch event.detail {
            case let .publishData(request):
                switch event.channelKind {
                case .lossy: lossyBuffering.queue.append(request)
                case .reliable: reliableBuffering.queue.append(request)
                }
            case let .bufferedAmountChanged(amount):
                switch event.channelKind {
                case .lossy: updateBufferingState(state: &lossyBuffering, newAmount: amount)
                case .reliable: updateBufferingState(state: &reliableBuffering, newAmount: amount)
                }
            }

            switch event.channelKind {
            case .lossy:
                processSendQueue(
                    threshold: Self.lossyLowThreshold,
                    state: &lossyBuffering,
                    kind: .lossy
                )
            case .reliable:
                processSendQueue(
                    threshold: Self.reliableLowThreshold,
                    state: &reliableBuffering,
                    kind: .reliable
                )
            }
        }
    }

    private func channel(for kind: ChannelKind) -> LKRTCDataChannel? {
        _state.read {
            guard let lossy = $0.lossy, let reliable = $0.reliable, $0.isOpen else { return nil }
            return kind == .reliable ? reliable : lossy
        }
    }

    private func processSendQueue(
        threshold: UInt64,
        state: inout BufferingState,
        kind: ChannelKind
    ) {
        while state.amount <= threshold {
            guard !state.queue.isEmpty else { break }
            let request = state.queue.removeFirst()

            state.amount += UInt64(request.data.data.count)

            guard let channel = channel(for: kind) else {
                request.continuation?.resume(
                    throwing: LiveKitError(.invalidState, message: "Data channel is not open")
                )
                return
            }
            guard channel.sendData(request.data) else {
                request.continuation?.resume(
                    throwing: LiveKitError(.invalidState, message: "sendData failed")
                )
                return
            }
            request.continuation?.resume()
        }
    }

    private func updateBufferingState(
        state: inout BufferingState,
        newAmount: UInt64
    ) {
        guard state.amount >= newAmount else {
            log("Unexpected buffer size detected", .error)
            state.amount = 0
            return
        }
        state.amount -= newAmount
    }

    public init(delegate: DataChannelDelegate? = nil,
                lossyChannel: LKRTCDataChannel? = nil,
                reliableChannel: LKRTCDataChannel? = nil)
    {
        _state = StateSync(State(lossy: lossyChannel,
                                 reliable: reliableChannel))

        if let delegate {
            delegates.add(delegate: delegate)
        }
        super.init()

        Task {
            let eventStream = AsyncStream<ChannelEvent> { continuation in
                self.eventContinuation = continuation
            }
            await handleEvents(events: eventStream)
        }
    }

    public func set(reliable channel: LKRTCDataChannel?) {
        let isOpen = _state.mutate {
            $0.reliable = channel
            return $0.isOpen
        }

        channel?.delegate = self

        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    public func set(lossy channel: LKRTCDataChannel?) {
        let isOpen = _state.mutate {
            $0.lossy = channel
            return $0.isOpen
        }

        channel?.delegate = self

        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    public func reset() {
        let (lossy, reliable) = _state.mutate {
            let result = ($0.lossy, $0.reliable)
            $0.reliable = nil
            $0.lossy = nil
            return result
        }

        lossy?.close()
        reliable?.close()

        openCompleter.reset()
    }

    public func send(userPacket: Livekit_UserPacket, kind: Livekit_DataPacket.Kind) async throws {
        try await send(dataPacket: .with {
            $0.kind = kind // TODO: field is deprecated
            $0.user = userPacket
        })
    }

    public func send(dataPacket packet: Livekit_DataPacket) async throws {
        let serializedData = try packet.serializedData()
        let rtcData = RTC.createDataBuffer(data: serializedData)

        try await withCheckedThrowingContinuation { continuation in
            let request = PublishDataRequest(
                data: rtcData,
                continuation: continuation
            )
            let event = ChannelEvent(
                channelKind: ChannelKind(packet.kind), // TODO: field is deprecated
                detail: .publishData(request)
            )
            eventContinuation?.yield(event)
        }
    }

    public func infos() -> [Livekit_DataChannelInfo] {
        _state.read { [$0.lossy, $0.reliable] }
            .compactMap { $0 }
            .map { $0.toLKInfoType() }
    }

    private static let reliableLowThreshold: UInt64 = 2 * 1024 * 1024 // 2 MB
    private static let lossyLowThreshold: UInt64 = reliableLowThreshold

    deinit {
        eventContinuation?.finish()
    }
}

// MARK: - RTCDataChannelDelegate

extension DataChannelPair: LKRTCDataChannelDelegate {
    func dataChannel(_ dataChannel: LKRTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        let event = ChannelEvent(
            channelKind: dataChannel.kind,
            detail: .bufferedAmountChanged(amount)
        )
        eventContinuation?.yield(event)
    }

    func dataChannelDidChangeState(_: LKRTCDataChannel) {
        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard let dataPacket = try? Livekit_DataPacket(serializedData: buffer.data) else {
            log("Could not decode data message", .error)
            return
        }

        delegates.notify {
            $0.dataChannel(self, didReceiveDataPacket: dataPacket)
        }
    }
}

private extension DataChannelPair.ChannelKind {
    init(_ packetKind: Livekit_DataPacket.Kind) {
        guard case .lossy = packetKind else {
            self = .reliable
            return
        }
        self = .lossy
    }
}

private extension LKRTCDataChannel {
    var kind: DataChannelPair.ChannelKind {
        guard label == LKRTCDataChannel.labels.lossy else {
            return .reliable
        }
        return .lossy
    }
}
