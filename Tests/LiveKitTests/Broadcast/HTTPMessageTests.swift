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

@testable import LiveKit
import XCTest

final class HTTPMessageTests: XCTestCase {
    func testHeaders() {
        var message = HTTPMessage()

        message[.contentType] = "application/json"
        XCTAssertEqual(message[.contentType], "application/json")

        message[.contentType] = nil
        XCTAssertNil(message[.contentType])
    }

    func testBody() {
        var message = HTTPMessage()

        let bodyString = "Hello world"
        message.body = Data(bodyString.utf8)
        XCTAssertEqual(message.body, Data(bodyString.utf8))
        XCTAssertEqual(message[.contentLength], String(bodyString.count))

        let updatedBodyString = bodyString + "!"
        message.body = Data(updatedBodyString.utf8)
        XCTAssertEqual(message[.contentLength], String(updatedBodyString.count))

        message.body = nil
        XCTAssertNil(message.body)
        XCTAssertNil(message[.contentLength])
    }

    func testValueSemantics() {
        var message1 = HTTPMessage()
        message1["Header"] = "Value"
        message1.body = Data("Body".utf8)

        var message2 = message1
        message2["Header"] = "New Value"
        message2.body = Data("New Body".utf8)

        XCTAssertEqual(message1["Header"], "Value")
        XCTAssertEqual(message1.body, Data("Body".utf8))
        XCTAssertEqual(message2["Header"], "New Value")
        XCTAssertEqual(message2.body, Data("New Body".utf8))
    }

    func testSerialization() throws {
        var message = HTTPMessage()
        message["Header"] = "Value"

        let data = try XCTUnwrap(Data(message))
        let decodedString = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssert(decodedString.contains("Value"))
    }
}
