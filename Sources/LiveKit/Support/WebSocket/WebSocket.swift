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

enum WebSocketMessage {
    case string(_ string: String)
    case data(_ data: Data)
}

enum WebSocketMigrationState {
    case started
    case completed
    case failed(_ error: Error)
}

internal protocol WebSocket {

    typealias OnMessage = (_ message: WebSocketMessage) -> Void
    typealias OnDisconnect = (_ reason: DisconnectReason) -> Void
    typealias OnDidUpdateMigrationState = (_ state: WebSocketMigrationState) -> Void

    var onMessage: OnMessage? { get set }
    var onDisconnect: OnDisconnect? { get set }
    var onDidUpdateMigrationState: OnDidUpdateMigrationState? { get set }

    init (url: URL,
          onMessage: OnMessage?,
          onDisconnect: OnDisconnect?,
          onDidUpdateMigrationState: OnDidUpdateMigrationState?)

    func connect() -> Promise<WebSocket>
    func send(data: Data) -> Promise<Void>
    func cleanUp(reason: DisconnectReason)
}