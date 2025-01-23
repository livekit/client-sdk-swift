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

final class HTTPMessageReaderTests: XCTestCase {
 
    private var reader: HTTPMessageReader!

    override func setUpWithError() throws {
        try super.setUpWithError()
        reader = HTTPMessageReader()
    }

    override func tearDownWithError() throws {
        reader = nil
        try super.tearDownWithError()
    }

    func testCompleteMessage() throws {
        let messageData = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!".utf8)
        let message = try XCTUnwrap(try reader.append(messageData))
        XCTAssertEqual(message[.contentType], "text/plain")
        
        let bodyData = try XCTUnwrap(message.body)
        let bodyString = try XCTUnwrap(String(data: bodyData, encoding: .utf8))
        XCTAssertEqual(bodyString, "Hello, World!")
    }

    func testIncompleteMessage() {
        let messageData = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n".utf8)
        XCTAssertThrowsError(try reader.append(messageData)) { error in
            guard case HTTPMessageReader.Error.incomplete(let remainingBytes) = error else {
                return XCTFail("Expected incomplete error, got: \(error)")
            }
            XCTAssertNil(remainingBytes)
        }
    }
    
    func testIncompleteMessageAfterContentLength() {
        let messageData = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nH".utf8)
        XCTAssertThrowsError(try reader.append(messageData)) { error in
            guard case HTTPMessageReader.Error.incomplete(let remainingBytes) = error else {
                return XCTFail("Expected incomplete error, got: \(error)")
            }
            XCTAssertEqual(remainingBytes, 12)
        }
    }
}
