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
import Network

internal class WebSocket_Network: NSObject, Loggable, WebSocket {

    public var onMessage: OnMessage?
    public var onDisconnect: OnDisconnect?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "LiveKitSDK.webSocket", qos: .default)

    private var connectPromise: Promise<WebSocket>?

    public static var defaultOptions: NWProtocolWebSocket.Options {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true

        return options
    }

    required public init(url: URL,
                         onMessage: OnMessage? = nil,
                         onDisconnect: OnDisconnect? = nil) {

        let params: NWParameters

        if url.scheme == "ws" {
            params = NWParameters.tcp
        } else {
            params = NWParameters.tls
        }

        params.defaultProtocolStack.applicationProtocols.insert(Self.defaultOptions, at: 0)

        connection = NWConnection(to: .url(url), using: params)
        self.onMessage = onMessage
        self.onDisconnect = onDisconnect

        super.init()

        connection.stateUpdateHandler = onStateUpdate
        connection.betterPathUpdateHandler = onBetterPath
    }

    private func onBetterPath(_ available: Bool) {
        log("available: \(available)")
    }

    private func onStateUpdate(_ state: NWConnection.State) {

        switch state {

        case .setup:
            log("setup")
        case .preparing:
            log("preparing")

        case .ready:
            log("ready")
            connectPromise?.fulfill(self)

        case .waiting(let error):
            log("waiting")
            cleanUp(reason: .network(error: error))
        case .failed(let error):
            log("failed")
            cleanUp(reason: .network(error: error))
        case .cancelled:
            log("cancelled")
            cleanUp(reason: .network())

        @unknown default:
            log("unknown")
        }
    }

    func connect() -> Promise<WebSocket> {
        receive()
        connection.start(queue: queue)
        let promise = Promise<WebSocket>.pending()
        connectPromise = promise
        return promise
    }

    private func receive() {

        queue.async {
            self.connection.receiveMessage { [weak self] data, context, _, error in

                guard let self = self else { return }

                if let error = error {
                    print("error: \(error)")
                    return
                }

                // unless it's an error, schedule another receive
                defer { self.receive() }

                guard let metadata = context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata else {
                    self.log("context is nil", .warning)
                    return
                }

                switch metadata.opcode {

                case .cont:
                    //
                    break
                case .text:
                    //
                    break
                case .binary:
                    if let data = data, let onMessage = self.onMessage {
                        print("connection did receive content, count: \(data.count)")
                        let message = WebSocketMessage.data(data)
                        onMessage(message)
                    }
                case .close:
                    //
                    break
                case .ping:
                    //
                    break
                case .pong:
                    //
                    break
                @unknown default:
                    self.log("unknown")
                }
            }
        }
    }

    func send(data: Data) -> Promise<Void> {

        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binaryContext",
                                                  metadata: [metadata])

        return Promise(on: queue) { complete, fail in

            self.connection.send(content: data,
                                 contentContext: context,
                                 completion: .contentProcessed({ error in

                                    if let error = error {
                                        fail(error)
                                    } else {
                                        complete(())
                                    }
                                 }))
        }
    }

    func cleanUp(reason: DisconnectReason) {

        if let promise = connectPromise {
            let sdkError = NetworkError.disconnected(message: "WebSocket disconnected")
            promise.reject(sdkError)
            connectPromise = nil
        }

        onMessage = nil
        onDisconnect = nil
        connection.cancel()
    }
}
