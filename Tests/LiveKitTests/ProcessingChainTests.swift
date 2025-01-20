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

class ProcessingChainTests: XCTestCase {
    // Mock processor for testing
    class MockProcessor: NSObject, ChainedProcessor {
        weak var nextProcessor: MockProcessor?

        func process(value: Int) -> Int {
            let result = value + 1
            return nextProcessor?.process(value: result) ?? result
        }
    }

    var chain: ProcessingChain<MockProcessor>!

    override func setUp() {
        super.setUp()
        chain = ProcessingChain<MockProcessor>()
    }

    override func tearDown() {
        chain = nil
        super.tearDown()
    }

    func test_initialState() {
        XCTAssertTrue(chain.isProcessorsEmpty)
        XCTAssertFalse(chain.isProcessorsNotEmpty)
        XCTAssertEqual(chain.countProcessors, 0)
        XCTAssertTrue(chain.allProcessors.isEmpty)
    }

    func test_addProcessor() {
        let processor = MockProcessor()
        chain.add(processor: processor)

        XCTAssertFalse(chain.isProcessorsEmpty)
        XCTAssertTrue(chain.isProcessorsNotEmpty)
        XCTAssertEqual(chain.countProcessors, 1)
        XCTAssertEqual(chain.allProcessors.count, 1)
    }

    func test_removeProcessor() {
        let processor = MockProcessor()
        chain.add(processor: processor)
        chain.remove(processor: processor)

        XCTAssertTrue(chain.isProcessorsEmpty)
        XCTAssertEqual(chain.countProcessors, 0)
        XCTAssertTrue(chain.allProcessors.isEmpty)
    }

    func test_removeAllProcessors() {
        let processor1 = MockProcessor()
        let processor2 = MockProcessor()

        chain.add(processor: processor1)
        chain.add(processor: processor2)
        XCTAssertEqual(chain.countProcessors, 2)

        chain.removeAllProcessors()
        XCTAssertTrue(chain.isProcessorsEmpty)
        XCTAssertEqual(chain.countProcessors, 0)
    }

    func test_buildProcessorChain() {
        let processor1 = MockProcessor()
        let processor2 = MockProcessor()
        let processor3 = MockProcessor()

        chain.add(processor: processor1)
        chain.add(processor: processor2)
        chain.add(processor: processor3)

        let builtChain = chain.buildProcessorChain()

        XCTAssertNotNil(builtChain)
        XCTAssertTrue(builtChain === processor1)
        XCTAssertTrue(processor1.nextProcessor === processor2)
        XCTAssertTrue(processor2.nextProcessor === processor3)
        XCTAssertNil(processor3.nextProcessor)
    }

    func test_buildEmptyChain() {
        XCTAssertNil(chain.buildProcessorChain())
    }

    func test_invokeProcessor() {
        let processor1 = MockProcessor()
        let processor2 = MockProcessor()
        let processor3 = MockProcessor()

        chain.add(processor: processor1)
        chain.add(processor: processor2)
        chain.add(processor: processor3)

        let result = chain.invokeProcessor { $0.process(value: 0) }

        // Each processor adds 1, so with 3 processors the final result should be 3
        XCTAssertEqual(result, 3)
    }

    func test_weakReference() {
        var processor: MockProcessor? = MockProcessor()
        chain.add(processor: processor!)

        XCTAssertEqual(chain.countProcessors, 1)

        // Remove strong reference to processor
        processor = nil

        // Since we're using weak references, the processor should be removed
        XCTAssertEqual(chain.countProcessors, 0)
    }
}
