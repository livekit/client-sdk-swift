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
import Starscream

internal class SocketClient: NSObject, Loggable {
	
	typealias OnMessage = (Any) -> Void
	typealias OnDisconnect = (_ reason: DisconnectReason?) -> Void
	
	public var onMessage: OnMessage?
	public var onDisconnect: OnDisconnect?
	
	private let queue = DispatchQueue(label: "LiveKitSDK.webSocket", qos: .default)
	private let operationQueue = OperationQueue()
	private let request: URLRequest
	
	private var disconnected = false
	private var connectPromise: Promise<SocketClient>?
	lazy var webSocket: WebSocket = {
		return WebSocket(request: request)
	}()
    static func connect(url: URL,
                        onMessage: OnMessage? = nil,
                        onDisconnect: OnDisconnect? = nil) -> Promise<SocketClient> {

        return SocketClient(url: url,
                         onMessage: onMessage,
                         onDisconnect: onDisconnect).connect()
    }

    private init(url: URL,
                 onMessage: OnMessage? = nil,
                 onDisconnect: OnDisconnect? = nil) {

        request = URLRequest(url: url,
                             cachePolicy: .useProtocolCachePolicy,
                             timeoutInterval: .defaultSocketConnect)

        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
        super.init()
		webSocket.delegate = self
		webSocket.connect()
    }

    private func connect() -> Promise<SocketClient> {
        connectPromise = .pending()
        return connectPromise!
    }

    internal func cleanUp(reason: DisconnectReason?) {

        log("reason: \(String(describing: reason))")

        guard !disconnected else {
            log("dispose can be called only once", .warning)
            return
        }

        // mark as disconnected, this instance cannot be re-used
        disconnected = true
		webSocket.disconnect()
        if let promise = connectPromise {
            let sdkError = NetworkError.disconnected(message: "WebSocket disconnected")
            promise.reject(sdkError)
            connectPromise = nil
        }

        onDisconnect?(reason)
    }

    public func send(data: Data) -> Promise<Void> {
        return Promise(on: .sdk) { resolve, fail in
			self.webSocket.write(data: data) {
				resolve(())
			}
        }
    }
}

extension SocketClient: WebSocketDelegate {
	func websocketDidConnect(socket: WebSocketClient) {
		disconnected = false
		connectPromise?.fulfill(self)
	}
	func websocketDidDisconnect(socket: WebSocketClient, error: Error?) {
		
		if let error = error {
			let err = error as NSError
			let sdkError = NetworkError.disconnected(message: "WebSocket did close with code: \(err.code) reason: \(String(describing: err.localizedDescription))")

			cleanUp(reason: .networkError(sdkError))
		} else {
			let error = NetworkError.disconnected(message: "WebSocket DidDisconnect")
			cleanUp(reason: .networkError(error))
		}
	}
	func websocketDidReceiveMessage(socket: WebSocketClient, text: String) {
		onMessage?(text)
	}
	func websocketDidReceiveData(socket: WebSocketClient, data: Data) {
		onMessage?(data)
	}
}
