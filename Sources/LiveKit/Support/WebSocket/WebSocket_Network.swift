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
    public var onDidUpdateMigrationState: OnDidUpdateMigrationState?

    private var connection: NWConnection
    private let queue = DispatchQueue(label: "LiveKitSDK.webSocket", qos: .default)

    private var connectPromise: Promise<WebSocket>?

    public static var defaultOptions: NWProtocolWebSocket.Options {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true

        return options
    }

    private let endpoint: NWEndpoint
    private let parameters: NWParameters

    required public init(url: URL,
                         onMessage: OnMessage? = nil,
                         onDisconnect: OnDisconnect? = nil,
                         onDidUpdateMigrationState: OnDidUpdateMigrationState? = nil) {

        self.endpoint = .url(url)

        let params: NWParameters

        if url.scheme == "ws" {
            params = NWParameters.tcp
        } else {
            params = NWParameters.tls
        }

        params.defaultProtocolStack.applicationProtocols.insert(Self.defaultOptions, at: 0)

        connection = NWConnection(to: endpoint, using: params)

        self.parameters = params
        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
        self.onDidUpdateMigrationState = onDidUpdateMigrationState

        super.init()

        connection.stateUpdateHandler = onStateUpdate(_:)
        connection.betterPathUpdateHandler = onBetterPath(_:)
    }

    private func onBetterPath(_ available: Bool) {
        log("available: \(available)")
        guard available else { return }

        self.onDidUpdateMigrationState?(.started)

        migrateConnection().then(on: queue) { [weak self] in
            guard let self = self else { return }
            self.log("socket migration complete")
            self.onDidUpdateMigrationState?(.completed)
        }.catch(on: queue) { [weak self] error in
            // migration failed
            guard let self = self else { return }
            self.log("socket migration failed: \(error)")
            self.onDidUpdateMigrationState?(.failed(error))
        }
    }

    private func migrateConnection() -> Promise<Void> {

        let migratedConnection = NWConnection(to: endpoint, using: parameters)

        return Promise(on: queue) { [weak self] complete, fail in

            guard let self = self else { return }

            migratedConnection.stateUpdateHandler = { [weak self] state in

                guard let self = self else { return }

                switch state {
                case .ready:

                    // cancel previous connection
                    // self.connection = nil

                    migratedConnection.stateUpdateHandler = self.onStateUpdate(_:)
                    migratedConnection.betterPathUpdateHandler = self.onBetterPath(_:)
                    // migratedConnection.viabilityUpdateHandler = self.viabilityDidChange(isViable:)
                    // let previousConnection = self.connection
                    self.connection.cancel()
                    self.connection = migratedConnection
                    self.receive()
                    complete(())
                case .waiting(let error):
                    fail(error)
                case .failed(let error):
                    fail(error)
                case .setup, .preparing:
                    break
                case .cancelled:
                    fail(NetworkError.disconnected(message: "Cancelled"))
                @unknown default:
                    fatalError()
                }
            }

            migratedConnection.start(queue: self.queue)
        }
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
            cleanUp(reason: .networkError(error))
        case .failed(let error):
            log("failed")
            cleanUp(reason: .networkError(error))
        case .cancelled:
            log("cancelled")
            cleanUp(reason: .networkError())

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
                    if let data = data, let onMessage = self.onMessage,
                       let string = String(data: data, encoding: .utf8) {
                        print("connection did receive text, count: \(string.count)")
                        let message = WebSocketMessage.string(string)
                        onMessage(message)
                    }
                case .binary:
                    if let data = data, let onMessage = self.onMessage {
                        print("connection did receive data, count: \(data.count)")
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

    func cleanUp(reason: DisconnectReason?) {

        onMessage = nil
        onDisconnect = nil
        onDidUpdateMigrationState = nil

        if let promise = connectPromise {
            let sdkError = NetworkError.disconnected(message: "WebSocket disconnected")
            promise.reject(sdkError)
            connectPromise = nil
        }

        connection.cancel()
    }
}
