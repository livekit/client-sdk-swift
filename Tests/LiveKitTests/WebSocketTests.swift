/*
 * Copyright 2024 LiveKit
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

@testable import LiveKit
import XCTest

class WebSocketTests: XCTestCase {
    override func setUpWithError() throws {}

    override func tearDown() async throws {}

    func testWebSocket01() async throws {
        print("Connecting...")
        let socket = try await WebSocket(url: URL(string: "wss://socketsbay.com/wss/v2/1/demo/")!)

        print("Connected, waiting for messages...")
        do {
            for try await message in socket {
                switch message {
                case let .string(string): print("Received String: \(string)")
                case let .data(data): print("Received Data: \(data)")
                @unknown default: print("Received unknown message")
                }
            }
        } catch {
            print("Error: \(error)")
            throw error
        }

        print("Completed")
    }
}
