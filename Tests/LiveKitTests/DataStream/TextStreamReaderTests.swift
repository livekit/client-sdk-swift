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

class TextStreamReaderTests: XCTestCase {
    
    func testInitialization() {
        let info = TextStreamInfo(
            id: UUID().uuidString,
            mimeType: "text/plain",
            topic: "someTopic",
            timestamp: Date(),
            totalLength: nil,
            attributes: [:],
            operationType: .create,
            version: 1,
            replyToStreamID: nil,
            attachedStreamIDs: [],
            generated: false
        )
        let source = StreamReaderSource { _ in }
        let reader = TextStreamReader(info: info, source: source)
        
        XCTAssertEqual(reader.info, info)
    }
}
