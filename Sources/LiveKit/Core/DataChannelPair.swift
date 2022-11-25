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
import WebRTC
import Promises

internal class DataChannelPair: NSObject, Loggable {

    // MARK: - Public

    public typealias OnDataPacket = (_ dataPacket: Livekit_DataPacket) -> Void

    public let target: Livekit_SignalTarget
    public var onDataPacket: OnDataPacket?

    public private(set) var openCompleter = Promise<Void>.pending()

    // MARK: - Private

    private var _reliableChannel: RTCDataChannel?
    private var _lossyChannel: RTCDataChannel?

    public var isOpen: Bool {

        guard let r = _reliableChannel,
              let l = _lossyChannel else {
            return false
        }

        return .open == r.readyState && .open == l.readyState
    }

    public init(target: Livekit_SignalTarget,
                reliableChannel: RTCDataChannel? = nil,
                lossyChannel: RTCDataChannel? = nil) {

        self.target = target
        self._reliableChannel = reliableChannel
        self._lossyChannel = lossyChannel
    }

    public func set(reliable channel: RTCDataChannel?) {
        self._reliableChannel = channel
        channel?.delegate = self

        if isOpen {
            openCompleter.fulfill(())
        }
    }

    public func set(lossy channel: RTCDataChannel?) {
        self._lossyChannel = channel
        channel?.delegate = self

        if isOpen {
            openCompleter.fulfill(())
        }
    }

    public func close() -> Promise<Void> {

        let r = _reliableChannel
        let l = _lossyChannel

        _reliableChannel = nil
        _lossyChannel = nil

        // reset completer
        openCompleter.reject(InternalError.state(message: "openCompleter did not complete"))
        openCompleter = Promise<Void>.pending()

        // execute on .webRTC queue
        return Promise(on: .webRTC) {
            r?.close()
            l?.close()
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

extension DataChannelPair: RTCDataChannelDelegate {

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {

        if isOpen {
            openCompleter.fulfill(())
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {

        guard let dataPacket = try? Livekit_DataPacket(contiguousBytes: buffer.data) else {
            log("could not decode data message", .error)
            return
        }

        onDataPacket?(dataPacket)
    }
}
