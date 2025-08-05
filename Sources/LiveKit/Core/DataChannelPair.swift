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

internal import LiveKitWebRTC

// MARK: - Internal delegate

protocol DataChannelDelegate: Sendable {
    func dataChannel(_ dataChannelPair: DataChannelPair, didReceiveDataPacket dataPacket: Livekit_DataPacket)
}

class DataChannelPair: NSObject, @unchecked Sendable, Loggable {
    // MARK: - Public

    let delegates = MulticastDelegate<DataChannelDelegate>(label: "DataChannelDelegate")

    let openCompleter = AsyncCompleter<Void>(label: "Data channel open", defaultTimeout: .defaultPublisherDataChannelOpen)

    var isOpen: Bool { _state.isOpen }

    // MARK: - Private

    private struct State {
        var lossy: LKRTCDataChannel?
        var reliable: LKRTCDataChannel?
        var reliableDataSequence: UInt32 = 1
        var reliableReceivedState: TTLDictionary<String, UInt32> = TTLDictionary(ttl: reliableReceivedStateTTL)

        var isOpen: Bool {
            guard let lossy, let reliable else { return false }
            return reliable.readyState == .open && lossy.readyState == .open
        }

        var eventContinuation: AsyncStream<ChannelEvent>.Continuation?
    }

    private let _state: StateSync<State>

    fileprivate enum ChannelKind {
        case lossy, reliable
    }

    private struct SendBuffer {
        private var queue: Deque<PublishDataRequest> = []
        var rtcAmount: UInt64 = 0

        mutating func enqueue(_ request: PublishDataRequest) {
            queue.append(request)
        }

        @discardableResult
        mutating func dequeue() -> PublishDataRequest? {
            guard !queue.isEmpty else { return nil }
            return queue.removeFirst()
        }

        func canSend(threshold: UInt64) -> Bool {
            rtcAmount <= threshold
        }
    }

    private struct RetryBuffer {
        private var queue: Deque<PublishDataRequest> = []
        private var currentAmount: UInt64 = 0
        private let minAmount: UInt64

        init(minAmount: UInt64) {
            self.minAmount = minAmount
        }

        func peek() -> PublishDataRequest? { queue.first }

        mutating func enqueue(_ request: PublishDataRequest) {
            queue.append(request)
            currentAmount += UInt64(request.data.data.count)
        }

        @discardableResult
        mutating func dequeue() -> PublishDataRequest? {
            guard !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            currentAmount -= UInt64(first.data.data.count)
            return first
        }

        mutating func trim(toAmount: UInt64) {
            while currentAmount > toAmount + minAmount {
                dequeue()
            }
        }
    }

    private struct PublishDataRequest: Sendable {
        let data: LKRTCDataBuffer
        let sequence: UInt32
        let continuation: CheckedContinuation<Void, any Error>?
    }

    private struct ChannelEvent: Sendable {
        let channelKind: ChannelKind
        let detail: Detail

        enum Detail: Sendable {
            case publishData(PublishDataRequest)
            case publishedData(PublishDataRequest)
            case bufferedAmountChanged(UInt64)
            case retryRequested(UInt32)
        }
    }

    // MARK: - Event handling

    private func handleEvents(
        events: AsyncStream<ChannelEvent>
    ) async {
        var lossyBuffer = SendBuffer()
        var reliableBuffer = SendBuffer()

        var reliableRetryBuffer = RetryBuffer(minAmount: Self.reliableRetryAmount)

        for await event in events {
            switch event.detail {
            case let .publishData(request):
                switch event.channelKind {
                case .lossy: lossyBuffer.enqueue(request)
                case .reliable: reliableBuffer.enqueue(request)
                }
            case let .publishedData(request):
                switch event.channelKind {
                case .lossy: ()
                case .reliable: reliableRetryBuffer.enqueue(request)
                }
            case let .bufferedAmountChanged(amount):
                switch event.channelKind {
                case .lossy:
                    updateTarget(buffer: &lossyBuffer, newAmount: amount)
                case .reliable:
                    updateTarget(buffer: &reliableBuffer, newAmount: amount)
                    reliableRetryBuffer.trim(toAmount: amount)
                }
            case let .retryRequested(lastSeq):
                switch event.channelKind {
                case .lossy: ()
                case .reliable: retry(buffer: &reliableRetryBuffer, from: lastSeq)
                }
            }

            switch event.channelKind {
            case .lossy:
                processSendQueue(
                    threshold: Self.lossyLowThreshold,
                    buffer: &lossyBuffer,
                    kind: .lossy
                )
            case .reliable:
                processSendQueue(
                    threshold: Self.reliableLowThreshold,
                    buffer: &reliableBuffer,
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
        buffer: inout SendBuffer,
        kind: ChannelKind
    ) {
        while buffer.canSend(threshold: threshold), let request = buffer.dequeue() {
            buffer.rtcAmount += UInt64(request.data.data.count)

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

            let event = ChannelEvent(channelKind: kind, detail: .publishedData(request))
            _state.eventContinuation?.yield(event)
        }
    }

    // MARK: - Cache

    private func updateTarget(
        buffer: inout SendBuffer,
        newAmount: UInt64
    ) {
        guard buffer.rtcAmount >= newAmount else {
            log("Unexpected buffer size detected", .error)
            buffer.rtcAmount = 0
            return
        }
        buffer.rtcAmount -= newAmount
    }

    private func retry(
        buffer: inout RetryBuffer,
        from lastSeq: UInt32
    ) {
        if let first = buffer.peek(), first.sequence > lastSeq + 1 {
            log("Wrong packet sequence while retrying: \(first.sequence) > \(lastSeq + 1), \(first.sequence - lastSeq - 1) packets missing", .warning)
        }
        while let request = buffer.dequeue() {
            if request.sequence > lastSeq {
                let event = ChannelEvent(channelKind: .reliable, detail: .publishData(PublishDataRequest(data: request.data, sequence: request.sequence, continuation: nil)))
                _state.eventContinuation?.yield(event)
            }
        }
    }

    // MARK: - Init

    init(delegate: DataChannelDelegate? = nil,
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
                _state.mutate { $0.eventContinuation = continuation }
            }
            await handleEvents(events: eventStream)
        }
    }

    func set(reliable channel: LKRTCDataChannel?) {
        let isOpen = _state.mutate {
            $0.reliable = channel
            return $0.isOpen
        }

        channel?.delegate = self

        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    func set(lossy channel: LKRTCDataChannel?) {
        let isOpen = _state.mutate {
            $0.lossy = channel
            return $0.isOpen
        }

        channel?.delegate = self

        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    func reset() {
        let (lossy, reliable) = _state.mutate {
            let result = ($0.lossy, $0.reliable)
            $0.reliable = nil
            $0.reliableDataSequence = 1
            $0.reliableReceivedState.removeAll()
            $0.lossy = nil
            return result
        }

        lossy?.close()
        reliable?.close()

        openCompleter.reset()
    }

    // MARK: - Send

    func send(userPacket: Livekit_UserPacket, kind: Livekit_DataPacket.Kind) async throws {
        try await send(dataPacket: .with {
            $0.kind = kind // TODO: field is deprecated
            $0.user = userPacket
        })
    }

    func send(dataPacket packet: Livekit_DataPacket) async throws {
        let packet = withSequence(packet)
        let serializedData = try packet.serializedData()
        let rtcData = RTC.createDataBuffer(data: serializedData)

        try await withCheckedThrowingContinuation { continuation in
            let request = PublishDataRequest(
                data: rtcData,
                sequence: packet.sequence,
                continuation: continuation
            )
            let event = ChannelEvent(
                channelKind: ChannelKind(packet.kind), // TODO: field is deprecated
                detail: .publishData(request)
            )
            _state.eventContinuation?.yield(event)
        }
    }

    private func withSequence(_ packet: Livekit_DataPacket) -> Livekit_DataPacket {
        guard packet.kind == .reliable, packet.sequence == 0 else { return packet }
        var packet = packet
        _state.mutate {
            packet.sequence = $0.reliableDataSequence
            $0.reliableDataSequence += 1
        }
        return packet
    }

    func retryReliable(lastSequence: UInt32) {
        let event = ChannelEvent(channelKind: .reliable, detail: .retryRequested(lastSequence))
        _state.eventContinuation?.yield(event)
    }

    // MARK: - Sync state

    func infos() -> [Livekit_DataChannelInfo] {
        _state.read { [$0.lossy, $0.reliable] }
            .compactMap { $0 }
            .map { $0.toLKInfoType() }
    }

    func receiveStates() -> [Livekit_DataChannelReceiveState] {
        _state.reliableReceivedState.map { sid, seq in
            Livekit_DataChannelReceiveState.with {
                $0.publisherSid = sid
                $0.lastSeq = seq
            }
        }
    }

    // MARK: - Constants

    private static let reliableLowThreshold: UInt64 = 2 * 1024 * 1024 // 2 MB
    private static let lossyLowThreshold: UInt64 = reliableLowThreshold

    // If rtc drains its buffer to 0, keep at least this amount of data for retry.
    // Should be >= the full backpressure amount to avoid losing packets.
    private static let reliableRetryAmount: UInt64 = .init(Double(reliableLowThreshold) * 1.25)
    private static let reliableReceivedStateTTL: TimeInterval = 30

    deinit {
        _state.eventContinuation?.finish()
    }
}

// MARK: - RTCDataChannelDelegate

extension DataChannelPair: LKRTCDataChannelDelegate {
    func dataChannel(_ dataChannel: LKRTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        let event = ChannelEvent(
            channelKind: dataChannel.kind,
            detail: .bufferedAmountChanged(amount)
        )
        _state.eventContinuation?.yield(event)
    }

    func dataChannelDidChangeState(_: LKRTCDataChannel) {
        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard let dataPacket = try? Livekit_DataPacket(serializedBytes: buffer.data) else {
            log("Could not decode data message", .error)
            return
        }

        if dataChannel.kind == .reliable, dataPacket.sequence > 0, !dataPacket.participantSid.isEmpty {
            if let lastSeq = _state.reliableReceivedState[dataPacket.participantSid], dataPacket.sequence <= lastSeq {
                log("Ignoring duplicate/out-of-order reliable data message", .warning)
                return
            }
            _state.mutate {
                $0.reliableReceivedState[dataPacket.participantSid] = dataPacket.sequence
            }
        }

        delegates.notify {
            $0.dataChannel(self, didReceiveDataPacket: dataPacket)
        }
    }
}

// MARK: - Extensions

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
