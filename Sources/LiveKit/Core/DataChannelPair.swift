/*
 * Copyright 2022 LiveKit
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
import Promises

@_implementationOnly import WebRTC

internal class DataChannelPair: NSObject, Loggable {

    // MARK: - Public

    public typealias OnDataPacket = (_ dataPacket: Livekit_DataPacket) -> Void

    public let target: Livekit_SignalTarget
    public var onDataPacket: OnDataPacket?

    public private(set) var openCompleter = AsyncCompleter<Void>(label: "Data channel open", timeOut: .defaultPublisherDataChannelOpen)

    // MARK: - Private

    private var _reliableChannel: LKRTCDataChannel?
    private var _lossyChannel: LKRTCDataChannel?

    public var isOpen: Bool {

        guard let reliable = _reliableChannel,
              let lossy = _lossyChannel else {
            return false
        }

        return .open == reliable.readyState && .open == lossy.readyState
    }

    public init(target: Livekit_SignalTarget,
                reliableChannel: LKRTCDataChannel? = nil,
                lossyChannel: LKRTCDataChannel? = nil) {

        self.target = target
        self._reliableChannel = reliableChannel
        self._lossyChannel = lossyChannel
    }

    public func set(reliable channel: LKRTCDataChannel?) {
        self._reliableChannel = channel
        channel?.delegate = self

        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    public func set(lossy channel: LKRTCDataChannel?) {
        self._lossyChannel = channel
        channel?.delegate = self

        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    public func close() {

        let reliable = _reliableChannel
        let lossy = _lossyChannel

        _reliableChannel = nil
        _lossyChannel = nil

        openCompleter.cancel()

        // execute on .webRTC queue
        DispatchQueue.liveKitWebRTC.sync {
            reliable?.close()
            lossy?.close()
        }
    }

    public func send(userPacket: Livekit_UserPacket, reliability: Reliability) throws {

        guard let reliableChannel = _reliableChannel,
              let lossyChannel = _lossyChannel else {

            throw InternalError.state(message: "Data channel is nil")
        }

        // prepare the data

        let packet = Livekit_DataPacket.with {
            $0.kind = reliability.toPBType()
            $0.user = userPacket
        }

        let serializedData = try packet.serializedData()
        let rtcData = Engine.createDataBuffer(data: serializedData)

        let result = { () -> Bool in
            switch reliability {
            case .reliable: return reliableChannel.sendData(rtcData)
            case .lossy: return lossyChannel.sendData(rtcData)
            }
        }()

        guard result else {
            throw InternalError.state(message: "sendData returned false")
        }
    }

    public func infos() -> [Livekit_DataChannelInfo] {

        [_lossyChannel, _reliableChannel]
            .compactMap { $0 }
            .map { $0.toLKInfoType() }
    }
}

// MARK: - RTCDataChannelDelegate

extension DataChannelPair: LKRTCDataChannelDelegate {

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {

        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {

        guard let dataPacket = try? Livekit_DataPacket(contiguousBytes: buffer.data) else {
            log("could not decode data message", .error)
            return
        }

        onDataPacket?(dataPacket)
    }
}
